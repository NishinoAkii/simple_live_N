#include "capture_channel.h"

#include <flutter/method_result_functions.h>
#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <cstdint>
#include <deque>
#include <mutex>
#include <string>
#include <utility>
#include <variant>

#include "capture_clipboard.h"
#include "capture_util.h"
#include "process_launch.h"

namespace {

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;

constexpr wchar_t kNotifyClass[] = L"SIMPLE_LIVE_CAPTURE_NOTIFY";
constexpr UINT kWakeMessage = WM_APP + 0x51;
constexpr UINT_PTR kStopTimer = 1;
// recordStop answers with an error if the file is not finished by then.
constexpr UINT kStopTimeoutMs = 10'000;
// Closing the window waits this long for the file to be finished.
constexpr DWORD kCloseWaitMs = 5'000;
// After its last event the recorder's thread ends right away.
constexpr DWORD kJoinWaitMs = 3'000;
// Sanity bounds for the area from Dart (physical pixels).
constexpr int64_t kMaxCoordinate = 100'000;

const EncodableValue* Field(const EncodableMap& map, const char* name) {
  auto found = map.find(EncodableValue(name));
  return found == map.end() ? nullptr : &found->second;
}

std::optional<int64_t> IntField(const EncodableMap& map, const char* name) {
  const EncodableValue* value = Field(map, name);
  if (value == nullptr) {
    return std::nullopt;
  }
  // Not "small": rpcndr.h defines it as a macro.
  if (const auto* value32 = std::get_if<int32_t>(value)) {
    return *value32;
  }
  if (const auto* value64 = std::get_if<int64_t>(value)) {
    return *value64;
  }
  return std::nullopt;
}

std::wstring Utf8ToWide(const std::string& text) {
  if (text.empty()) {
    return std::wstring();
  }
  const int length =
      ::MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(),
                            static_cast<int>(text.size()), nullptr, 0);
  if (length <= 0) {
    return std::wstring();
  }
  std::wstring wide(static_cast<size_t>(length), L'\0');
  ::MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(),
                        static_cast<int>(text.size()), wide.data(), length);
  return wide;
}

EncodableValue SummaryValue(const RecordSummary& summary) {
  EncodableMap map = {
      {EncodableValue("path"), EncodableValue(summary.path)},
      {EncodableValue("durationMs"), EncodableValue(summary.duration_ms)},
      {EncodableValue("bytes"), EncodableValue(summary.bytes)},
      {EncodableValue("audio"), EncodableValue(summary.audio)},
      {EncodableValue("width"), EncodableValue(summary.width)},
      {EncodableValue("height"), EncodableValue(summary.height)},
      {EncodableValue("frames"), EncodableValue(summary.frames)},
      {EncodableValue("droppedFrames"),
       EncodableValue(summary.dropped_frames)},
      {EncodableValue("encoder"), EncodableValue(summary.encoder)},
      {EncodableValue("reason"), EncodableValue(summary.reason)},
  };
  if (!summary.audio_note.empty()) {
    map[EncodableValue("audioNote")] = EncodableValue(summary.audio_note);
  }
  if (!summary.error.empty()) {
    map[EncodableValue("error")] = EncodableValue(summary.error);
  }
  return EncodableValue(std::move(map));
}

}  // namespace

// Events from the recorder's thread, handed to the platform thread through
// the notify window. Shared with the recorder's callback, so a recorder that
// outlives the channel (window closed mid-way) still has somewhere to post.
struct CaptureChannel::EventQueue {
  void Push(RecorderEvent event) {
    std::lock_guard<std::mutex> lock(mutex);
    events.push_back(std::move(event));
    if (target != nullptr) {
      ::PostMessageW(target, kWakeMessage, 0, 0);
    }
  }
  // A watched process ended (called on a thread pool thread).
  void PushExit(DWORD pid) {
    std::lock_guard<std::mutex> lock(mutex);
    exits.push_back(pid);
    if (target != nullptr) {
      ::PostMessageW(target, kWakeMessage, 0, 0);
    }
  }
  std::deque<RecorderEvent> Take() {
    std::lock_guard<std::mutex> lock(mutex);
    return std::exchange(events, std::deque<RecorderEvent>());
  }
  std::deque<DWORD> TakeExits() {
    std::lock_guard<std::mutex> lock(mutex);
    return std::exchange(exits, std::deque<DWORD>());
  }
  void SetTarget(HWND window) {
    std::lock_guard<std::mutex> lock(mutex);
    target = window;
  }

  std::mutex mutex;
  std::deque<RecorderEvent> events;
  std::deque<DWORD> exits;
  HWND target = nullptr;
};

// What the thread pool wait of one process reports to.
struct CaptureChannel::WaitContext {
  std::shared_ptr<EventQueue> queue;
  DWORD pid = 0;
};

// static
VOID CALLBACK CaptureChannel::OnProcessSignaled(PVOID context,
                                                BOOLEAN timed_out) {
  auto* wait = static_cast<WaitContext*>(context);
  wait->queue->PushExit(wait->pid);
}

namespace {

std::optional<DWORD> PidField(const EncodableMap* arguments) {
  if (arguments == nullptr) {
    return std::nullopt;
  }
  const auto pid = IntField(*arguments, "pid");
  if (!pid || *pid <= 0 || *pid > static_cast<int64_t>(MAXDWORD)) {
    return std::nullopt;
  }
  return static_cast<DWORD>(*pid);
}

}  // namespace

CaptureChannel::CaptureChannel(flutter::BinaryMessenger* messenger,
                               HWND window)
    : window_(window), events_(std::make_shared<EventQueue>()) {
  const HINSTANCE instance = ::GetModuleHandleW(nullptr);
  WNDCLASSEXW window_class = {};
  window_class.cbSize = sizeof(window_class);
  window_class.lpfnWndProc = &CaptureChannel::NotifyProc;
  window_class.hInstance = instance;
  window_class.lpszClassName = kNotifyClass;
  // Fails harmlessly when the class is registered already.
  ::RegisterClassExW(&window_class);
  notify_ = ::CreateWindowExW(0, kNotifyClass, L"", 0, 0, 0, 0, 0,
                              HWND_MESSAGE, nullptr, instance, nullptr);
  if (notify_ != nullptr) {
    ::SetWindowLongPtrW(notify_, GWLP_USERDATA,
                        reinterpret_cast<LONG_PTR>(this));
  }
  events_->SetTarget(notify_);

  channel_ = std::make_unique<Channel>(
      messenger, "simple_live/capture",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    OnCall(call, std::move(result));
  });
}

CaptureChannel::~CaptureChannel() {
  Shutdown();
}

void CaptureChannel::Shutdown() {
  if (shut_down_) {
    return;
  }
  shut_down_ = true;
  if (recorder_) {
    recorder_->RequestStop(StopReason::kWindowClosed);
    if (recorder_->Wait(kCloseWaitMs)) {
      // Answers a pending recordStop with the finished file.
      DrainEvents();
    } else {
      // Not finished in time; the process is about to end anyway.
      recorder_->Detach();
      ScreenRecorder* abandoned = recorder_.release();
      (void)abandoned;
    }
  }
  if (start_result_) {
    start_result_->Error("start_failed", "the window was closed");
    start_result_.reset();
  }
  for (auto& result : stop_results_) {
    result->Error("record_failed", "the window was closed");
  }
  stop_results_.clear();
  ReleaseProcesses();
  alive_.reset();
  events_->SetTarget(nullptr);
  if (notify_ != nullptr) {
    ::KillTimer(notify_, kStopTimer);
    ::SetWindowLongPtrW(notify_, GWLP_USERDATA, 0);
    ::DestroyWindow(notify_);
    notify_ = nullptr;
  }
  if (channel_) {
    channel_->SetMethodCallHandler(nullptr);
    channel_.reset();
  }
}

void CaptureChannel::OnCall(
    const flutter::MethodCall<flutter::EncodableValue>& call, Result result) {
  const std::string& method = call.method_name();
  const EncodableValue* arguments = call.arguments();
  const auto* map =
      arguments == nullptr ? nullptr : std::get_if<EncodableMap>(arguments);

  if (method == "copyImage") {
    bool done = false;
    const EncodableValue* png = map == nullptr ? nullptr : Field(*map, "png");
    if (png != nullptr) {
      if (const auto* bytes = std::get_if<std::vector<uint8_t>>(png)) {
        done = CopyPngToClipboard(window_, *bytes);
      }
    }
    result->Success(EncodableValue(done));
    return;
  }
  if (method == "copyFiles") {
    std::vector<std::wstring> paths;
    const EncodableValue* value =
        map == nullptr ? nullptr : Field(*map, "paths");
    const auto* list =
        value == nullptr ? nullptr : std::get_if<EncodableList>(value);
    if (list != nullptr) {
      for (const auto& item : *list) {
        if (const auto* path = std::get_if<std::string>(&item)) {
          paths.push_back(Utf8ToWide(*path));
        }
      }
    }
    result->Success(
        EncodableValue(!paths.empty() && CopyFilesToClipboard(window_, paths)));
    return;
  }
  if (method == "copyGif") {
    const EncodableValue* value =
        map == nullptr ? nullptr : Field(*map, "path");
    const auto* path =
        value == nullptr ? nullptr : std::get_if<std::string>(value);
    result->Success(EncodableValue(
        path != nullptr && CopyGifToClipboard(window_, Utf8ToWide(*path))));
    return;
  }
  if (method == "recordStart") {
    OnRecordStart(map, std::move(result));
    return;
  }
  if (method == "recordStop") {
    OnRecordStop(std::move(result));
    return;
  }
  if (method == "recordActive") {
    result->Success(EncodableValue(state_ != State::kIdle));
    return;
  }
  if (method == "launchDetached") {
    OnLaunchDetached(map, std::move(result));
    return;
  }
  if (method == "waitPid") {
    OnWaitPid(map, std::move(result));
    return;
  }
  if (method == "killPid") {
    OnKillPid(map, std::move(result));
    return;
  }
  result->NotImplemented();
}

void CaptureChannel::OnRecordStart(const EncodableMap* arguments,
                                   Result result) {
  if (shut_down_ || notify_ == nullptr) {
    result->Error("start_failed", "recording is not available");
    return;
  }
  if (state_ != State::kIdle) {
    result->Error("busy", "a recording is already running in this window");
    return;
  }
  const EncodableValue* path_value =
      arguments == nullptr ? nullptr : Field(*arguments, "path");
  const auto* path =
      path_value == nullptr ? nullptr : std::get_if<std::string>(path_value);
  if (path == nullptr || path->empty()) {
    result->Error("bad_args", "path missing");
    return;
  }
  const auto x = IntField(*arguments, "x");
  const auto y = IntField(*arguments, "y");
  const auto width = IntField(*arguments, "width");
  const auto height = IntField(*arguments, "height");
  const auto fps = IntField(*arguments, "fps");
  if (!x || !y || !width || !height || !fps) {
    result->Error("bad_args", "x, y, width, height and fps are required");
    return;
  }
  if (*width <= 0 || *height <= 0 || *width > kMaxCoordinate ||
      *height > kMaxCoordinate || *x < -kMaxCoordinate ||
      *x > kMaxCoordinate || *y < -kMaxCoordinate || *y > kMaxCoordinate) {
    result->Error("bad_args", "area out of range");
    return;
  }
  if (*fps < 1 || *fps > 120) {
    result->Error("bad_args", "fps must be 1 to 120");
    return;
  }
  capture::Size output;
  if (!capture::EncodeSize(static_cast<int>(*width), static_cast<int>(*height),
                           &output)) {
    result->Error("unsupported",
                  "area must be 16 to 4096 px (at most 4096x2304)");
    return;
  }
  if (::IsIconic(window_)) {
    result->Error("start_failed", "the window is minimized");
    return;
  }
  RECT client = {};
  ::GetClientRect(window_, &client);
  if (*x >= client.right || *y >= client.bottom || *x + *width <= 0 ||
      *y + *height <= 0) {
    result->Error("bad_args", "area is outside the window");
    return;
  }
  bool audio = false;
  if (const EncodableValue* value = Field(*arguments, "audio")) {
    if (const auto* flag = std::get_if<bool>(value)) {
      audio = *flag;
    }
  }

  RecordOptions options;
  options.path_utf8 = *path;
  options.path = Utf8ToWide(*path);
  std::replace(options.path.begin(), options.path.end(), L'/', L'\\');
  if (options.path.empty()) {
    result->Error("bad_args", "path is not valid UTF-8");
    return;
  }
  options.area.x = static_cast<int>(*x);
  options.area.y = static_cast<int>(*y);
  options.area.width = static_cast<int>(*width);
  options.area.height = static_cast<int>(*height);
  options.fps = static_cast<int>(*fps);
  options.audio = audio;
  options.max_seconds = std::max<int64_t>(
      IntField(*arguments, "maxSeconds").value_or(0), 0);

  unclaimed_.reset();
  recorder_ = ScreenRecorder::Create(
      window_, std::move(options),
      [events = events_](RecorderEvent event) {
        events->Push(std::move(event));
      });
  state_ = State::kStarting;
  start_result_ = std::move(result);
  recorder_->Start();
}

void CaptureChannel::OnRecordStop(Result result) {
  switch (state_) {
    case State::kIdle:
      if (unclaimed_) {
        const RecordSummary summary = std::move(*unclaimed_);
        unclaimed_.reset();
        if (summary.ok) {
          result->Success(SummaryValue(summary));
        } else {
          result->Error("record_failed", summary.error, SummaryValue(summary));
        }
      } else {
        result->Error("not_recording", "nothing is being recorded");
      }
      return;
    case State::kStarting:
      // Stopped as soon as it runs.
      stop_results_.push_back(std::move(result));
      return;
    case State::kRecording:
      stop_results_.push_back(std::move(result));
      BeginStop(StopReason::kRequested);
      return;
    case State::kStopping:
      stop_results_.push_back(std::move(result));
      return;
  }
}

void CaptureChannel::BeginStop(StopReason reason) {
  recorder_->RequestStop(reason);
  state_ = State::kStopping;
  ::SetTimer(notify_, kStopTimer, kStopTimeoutMs, nullptr);
}

void CaptureChannel::DrainEvents() {
  for (const RecorderEvent& event : events_->Take()) {
    if (event.kind == RecorderEvent::Kind::kStarted) {
      OnStarted(event);
    } else {
      OnFinished(event);
    }
  }
  for (const DWORD pid : events_->TakeExits()) {
    OnProcessExited(pid);
  }
}

void CaptureChannel::OnLaunchDetached(const EncodableMap* arguments,
                                      Result result) {
  const EncodableValue* exe_value =
      arguments == nullptr ? nullptr : Field(*arguments, "exe");
  const auto* exe =
      exe_value == nullptr ? nullptr : std::get_if<std::string>(exe_value);
  if (exe == nullptr || exe->empty()) {
    result->Error("bad_args", "exe missing");
    return;
  }
  std::vector<std::wstring> args;
  if (const EncodableValue* value = Field(*arguments, "args")) {
    if (const auto* list = std::get_if<EncodableList>(value)) {
      for (const auto& item : *list) {
        if (const auto* text = std::get_if<std::string>(&item)) {
          args.push_back(Utf8ToWide(*text));
        }
      }
    }
  }
  std::wstring directory;
  if (const EncodableValue* value = Field(*arguments, "cwd")) {
    if (const auto* text = std::get_if<std::string>(value)) {
      directory = Utf8ToWide(*text);
    }
  }
  LaunchResult launched = LaunchDetached(Utf8ToWide(*exe), args, directory);
  if (launched.process == nullptr) {
    result->Error("launch_failed", launched.note);
    return;
  }
  Tracked& tracked = processes_[launched.pid];
  if (tracked.process != nullptr) {
    // Cannot happen while the old handle is open; keep the newer one.
    ::CloseHandle(tracked.process);
  }
  tracked.process = launched.process;
  EncodableMap map = {
      {EncodableValue("pid"),
       EncodableValue(static_cast<int64_t>(launched.pid))},
      {EncodableValue("reparented"), EncodableValue(launched.reparented)},
  };
  if (!launched.note.empty()) {
    map[EncodableValue("note")] = EncodableValue(launched.note);
  }
  result->Success(EncodableValue(std::move(map)));
}

void CaptureChannel::OnWaitPid(const EncodableMap* arguments, Result result) {
  const std::optional<DWORD> pid = PidField(arguments);
  if (!pid || shut_down_) {
    result->Success(EncodableValue());
    return;
  }
  auto found = processes_.find(*pid);
  if (found == processes_.end()) {
    // Not started here: only a running process of this exe is waited for.
    HANDLE process = ::OpenProcess(SYNCHRONIZE | PROCESS_TERMINATE |
                                       PROCESS_QUERY_LIMITED_INFORMATION,
                                   FALSE, *pid);
    if (process == nullptr || !IsSameExe(process)) {
      if (process != nullptr) {
        ::CloseHandle(process);
      }
      result->Success(EncodableValue());
      return;
    }
    found = processes_.emplace(*pid, Tracked{}).first;
    found->second.process = process;
  }
  Tracked& tracked = found->second;
  tracked.waiters.push_back(std::move(result));
  if (tracked.wait != nullptr) {
    return;
  }
  auto* context = new WaitContext{events_, *pid};
  if (::RegisterWaitForSingleObject(&tracked.wait, tracked.process,
                                    &CaptureChannel::OnProcessSignaled,
                                    context, INFINITE, WT_EXECUTEONLYONCE)) {
    tracked.context = context;
    return;
  }
  tracked.wait = nullptr;
  delete context;
  if (::WaitForSingleObject(tracked.process, 0) == WAIT_OBJECT_0) {
    OnProcessExited(*pid);
    return;
  }
  auto waiters = std::move(tracked.waiters);
  tracked.waiters.clear();
  for (auto& waiter : waiters) {
    waiter->Error("wait_failed", "cannot watch the process");
  }
}

void CaptureChannel::OnKillPid(const EncodableMap* arguments, Result result) {
  const std::optional<DWORD> pid = PidField(arguments);
  bool killed = false;
  if (pid) {
    auto found = processes_.find(*pid);
    if (found != processes_.end()) {
      killed = TerminateIfSameExe(found->second.process);
    } else {
      HANDLE process = ::OpenProcess(
          PROCESS_TERMINATE | PROCESS_QUERY_LIMITED_INFORMATION, FALSE, *pid);
      if (process != nullptr) {
        killed = TerminateIfSameExe(process);
        ::CloseHandle(process);
      }
    }
  }
  result->Success(EncodableValue(killed));
}

void CaptureChannel::OnProcessExited(DWORD pid) {
  auto found = processes_.find(pid);
  if (found == processes_.end()) {
    return;
  }
  Tracked tracked = std::move(found->second);
  processes_.erase(found);
  if (tracked.wait != nullptr) {
    // The callback has run (it posted this); wait for it to return.
    ::UnregisterWaitEx(tracked.wait, INVALID_HANDLE_VALUE);
  }
  delete tracked.context;
  DWORD code = 0;
  const bool known = ::GetExitCodeProcess(tracked.process, &code) &&
                     code != STILL_ACTIVE;
  ::CloseHandle(tracked.process);
  for (auto& waiter : tracked.waiters) {
    waiter->Success(known ? EncodableValue(static_cast<int64_t>(code))
                          : EncodableValue());
  }
}

void CaptureChannel::ReleaseProcesses() {
  // The windows keep running; only our watch on them ends.
  for (auto& entry : processes_) {
    Tracked& tracked = entry.second;
    if (tracked.wait != nullptr) {
      ::UnregisterWaitEx(tracked.wait, INVALID_HANDLE_VALUE);
    }
    delete tracked.context;
    for (auto& waiter : tracked.waiters) {
      waiter->Error("closed", "the window was closed");
    }
    ::CloseHandle(tracked.process);
  }
  processes_.clear();
}

void CaptureChannel::OnStarted(const RecorderEvent& event) {
  if (!event.error_code.empty()) {
    JoinRecorder();
    state_ = State::kIdle;
    if (start_result_) {
      start_result_->Error(event.error_code, event.error_message);
      start_result_.reset();
    }
    for (auto& result : stop_results_) {
      result->Error("not_recording", "the recording did not start");
    }
    stop_results_.clear();
    return;
  }
  state_ = State::kRecording;
  if (start_result_) {
    start_result_->Success(EncodableValue(true));
    start_result_.reset();
  }
  if (!stop_results_.empty()) {
    BeginStop(StopReason::kRequested);
  }
}

void CaptureChannel::OnFinished(const RecorderEvent& event) {
  if (notify_ != nullptr) {
    ::KillTimer(notify_, kStopTimer);
  }
  JoinRecorder();
  state_ = State::kIdle;
  const RecordSummary& summary = event.summary;
  if (stop_results_.empty()) {
    // Ended by itself (limit, error, window closing).
    unclaimed_ = summary;
    ++unclaimed_id_;
    // While the window closes (Shutdown) the file is only finished.
    if (!shut_down_) {
      NotifyStopped();
    }
    return;
  }
  for (auto& result : stop_results_) {
    if (summary.ok) {
      result->Success(SummaryValue(summary));
    } else {
      result->Error("record_failed", summary.error, SummaryValue(summary));
    }
  }
  stop_results_.clear();
}

void CaptureChannel::OnStopTimeout() {
  ::KillTimer(notify_, kStopTimer);
  for (auto& result : stop_results_) {
    result->Error("stop_timeout", "the file is still being finished");
  }
  stop_results_.clear();
}

void CaptureChannel::NotifyStopped() {
  if (!channel_ || !unclaimed_) {
    return;
  }
  const uint64_t id = unclaimed_id_;
  const std::weak_ptr<bool> alive = alive_;
  // Dart took it: recordStop no longer returns it. No handler or an error:
  // it stays for the next recordStop.
  auto claimed = [this, alive, id](const EncodableValue* reply) {
    if (alive.lock() && unclaimed_id_ == id) {
      unclaimed_.reset();
    }
  };
  channel_->InvokeMethod(
      "onRecordStopped",
      std::make_unique<EncodableValue>(SummaryValue(*unclaimed_)),
      std::make_unique<flutter::MethodResultFunctions<EncodableValue>>(
          claimed, nullptr, nullptr));
}

void CaptureChannel::JoinRecorder() {
  if (!recorder_) {
    return;
  }
  if (recorder_->Wait(kJoinWaitMs)) {
    recorder_.reset();
  } else {
    recorder_->Detach();
    ScreenRecorder* abandoned = recorder_.release();
    (void)abandoned;
  }
}

// static
LRESULT CALLBACK CaptureChannel::NotifyProc(HWND hwnd, UINT message,
                                            WPARAM wparam, LPARAM lparam) {
  auto* self = reinterpret_cast<CaptureChannel*>(
      ::GetWindowLongPtrW(hwnd, GWLP_USERDATA));
  if (self != nullptr) {
    if (message == kWakeMessage) {
      self->DrainEvents();
      return 0;
    }
    if (message == WM_TIMER && wparam == kStopTimer) {
      self->OnStopTimeout();
      return 0;
    }
  }
  return ::DefWindowProcW(hwnd, message, wparam, lparam);
}
