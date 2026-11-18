#ifndef RUNNER_CAPTURE_CHANNEL_H_
#define RUNNER_CAPTURE_CHANNEL_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <cstdint>
#include <map>
#include <memory>
#include <optional>
#include <vector>

#include "screen_recorder.h"

// MethodChannel simple_live/capture of one window process:
//   copyImage({png})          -> bool   PNG to the clipboard
//   copyFiles({paths})        -> bool   files to the clipboard
//   copyGif({path})           -> bool   GIF bytes, file and first frame
//   recordStart({path, x, y, width, height, fps, audio, maxSeconds?}) -> true
//                                       or an error (code + short message)
//   recordStop()              -> {path, durationMs, bytes, audio, ...}
//   recordActive()            -> bool
// and to Dart, when a recording ends without recordStop (limit, error):
//   onRecordStopped({...the recordStop map..., reason})
// One recording per process at a time.
//
// Secondary windows (Windows only; see process_launch.h):
//   launchDetached({exe, args, cwd?}) -> {pid, reparented, note?}
//   waitPid({pid})            -> exit code (null if unknown) once it ended
//   killPid({pid})            -> bool   only a process of this same exe
class CaptureChannel {
 public:
  // [window]: the top-level window that is recorded and owns the clipboard.
  CaptureChannel(flutter::BinaryMessenger* messenger, HWND window);
  ~CaptureChannel();
  CaptureChannel(const CaptureChannel&) = delete;
  CaptureChannel& operator=(const CaptureChannel&) = delete;

  // Stops a running recording (waits a few seconds at most for the file to
  // be finished) and answers every pending call. Call while the engine runs.
  void Shutdown();

 private:
  using Channel = flutter::MethodChannel<flutter::EncodableValue>;
  using Result =
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>;
  struct EventQueue;
  struct WaitContext;

  // A process from launchDetached (or asked about by waitPid).
  struct Tracked {
    HANDLE process = nullptr;
    // Thread pool wait for its end, while someone waits.
    HANDLE wait = nullptr;
    WaitContext* context = nullptr;
    std::vector<Result> waiters;
  };

  enum class State { kIdle, kStarting, kRecording, kStopping };

  void OnCall(const flutter::MethodCall<flutter::EncodableValue>& call,
              Result result);
  void OnRecordStart(const flutter::EncodableMap* arguments, Result result);
  void OnRecordStop(Result result);
  void BeginStop(StopReason reason);
  // Handles what the recorder's thread reported (on the platform thread).
  void DrainEvents();
  void OnStarted(const RecorderEvent& event);
  void OnFinished(const RecorderEvent& event);
  void OnStopTimeout();
  void JoinRecorder();
  // Tells Dart about a recording that ended by itself. The summary stays
  // unclaimed_ until Dart's handler answers, so without a handler the next
  // recordStop still gets it.
  void NotifyStopped();
  void OnLaunchDetached(const flutter::EncodableMap* arguments, Result result);
  void OnWaitPid(const flutter::EncodableMap* arguments, Result result);
  void OnKillPid(const flutter::EncodableMap* arguments, Result result);
  // Answers the waitPid calls of a process that ended and forgets it.
  void OnProcessExited(DWORD pid);
  void ReleaseProcesses();
  // Thread pool callback: a watched process ended.
  static VOID CALLBACK OnProcessSignaled(PVOID context, BOOLEAN timed_out);

  static LRESULT CALLBACK NotifyProc(HWND hwnd, UINT message, WPARAM wparam,
                                     LPARAM lparam);

  const HWND window_;
  // Message-only window: the recorder's thread posts to it, so its events
  // are handled on the platform thread.
  HWND notify_ = nullptr;
  std::unique_ptr<Channel> channel_;
  std::shared_ptr<EventQueue> events_;
  std::unique_ptr<ScreenRecorder> recorder_;
  State state_ = State::kIdle;
  Result start_result_;
  std::vector<Result> stop_results_;
  // A recording that ended by itself (limit, error) and was not collected
  // by recordStop yet.
  std::optional<RecordSummary> unclaimed_;
  // Which unclaimed_ an onRecordStopped answer belongs to.
  uint64_t unclaimed_id_ = 0;
  // Gone after Shutdown: late answers from Dart must not touch this object.
  std::shared_ptr<bool> alive_ = std::make_shared<bool>(true);
  bool shut_down_ = false;
  // By pid. The open handle keeps the pid from being reused meanwhile.
  std::map<DWORD, Tracked> processes_;
};

#endif  // RUNNER_CAPTURE_CHANNEL_H_
