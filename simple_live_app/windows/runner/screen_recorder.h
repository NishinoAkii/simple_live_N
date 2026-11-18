#ifndef RUNNER_SCREEN_RECORDER_H_
#define RUNNER_SCREEN_RECORDER_H_

#include <windows.h>

#include <cstdint>
#include <functional>
#include <memory>
#include <string>

#include "capture_util.h"

// Records an area of a window's client area to an MP4 file, with what the
// process plays as the sound track. See screen_recorder.cpp.

struct RecordOptions {
  std::wstring path;
  // The same path as given by Dart, for the result.
  std::string path_utf8;
  // Client coordinates, physical pixels.
  capture::Rect area;
  int fps = 30;
  bool audio = false;
  // The user's limit, 0 = none. The recording stops by itself 30 s after it
  // (or after 4 hours without a limit), in case Dart does not stop it.
  int64_t max_seconds = 0;
};

enum class StopReason : int {
  kNone = 0,
  kRequested,
  kWindowClosed,
  kLimit,
  kError,
};

struct RecordSummary {
  // The file was finished and can be played.
  bool ok = false;
  // Why it was not, or what went wrong on the way.
  std::string error;
  // "stopped", "closed" (window closed), "limit" or "error".
  std::string reason;
  std::string path;
  int64_t duration_ms = 0;
  int64_t bytes = 0;
  int64_t frames = 0;
  int64_t dropped_frames = 0;
  int width = 0;
  int height = 0;
  // The file has the captured sound track.
  bool audio = false;
  // Why there is no sound track although one was asked for.
  std::string audio_note;
  // "hardware" or "software" H.264 encoder.
  std::string encoder;
};

struct RecorderEvent {
  enum class Kind { kStarted, kFinished };
  Kind kind = Kind::kStarted;
  // kStarted: empty when the recording runs, otherwise why it did not start.
  std::string error_code;
  std::string error_message;
  // kFinished
  RecordSummary summary;
};

class ScreenRecorder {
 public:
  // Called on the recorder's own thread: one kStarted event, then one
  // kFinished event if the recording started.
  using EventCallback = std::function<void(RecorderEvent)>;

  // [window]: the top-level window whose client area is recorded.
  static std::unique_ptr<ScreenRecorder> Create(HWND window,
                                                RecordOptions options,
                                                EventCallback on_event);

  virtual ~ScreenRecorder() = default;

  // Starts the recorder's thread. Everything else happens there.
  virtual void Start() = 0;
  // Asks the recording to stop and finish the file. Returns at once.
  virtual void RequestStop(StopReason reason) = 0;
  // Waits up to [timeout_ms] for the thread to end. True when it ended.
  virtual bool Wait(DWORD timeout_ms) = 0;
  // Gives up on a thread that did not end in time. The object must then be
  // leaked, since the thread still uses it.
  virtual void Detach() = 0;
};

#endif  // RUNNER_SCREEN_RECORDER_H_
