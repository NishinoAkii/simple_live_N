#ifndef RUNNER_CAPTURE_UTIL_H_
#define RUNNER_CAPTURE_UTIL_H_

// Pure helpers of the capture module: no Direct3D, no Media Foundation, so a
// console test can check them without the app.

#include <cstdint>
#include <string>
#include <vector>

namespace capture {

struct Size {
  int width = 0;
  int height = 0;
};

// A rectangle in physical pixels.
struct Rect {
  int x = 0;
  int y = 0;
  int width = 0;
  int height = 0;
};

// H.264 levels 5.1 and 5.2 allow 36864 macroblocks per frame (4096x2304),
// which is also what hardware encoders take at most.
constexpr int kMinEncodeSide = 16;
constexpr int kMaxEncodeSide = 4096;
constexpr int kMaxEncodeMacroblocks = 36864;

// The encoded frame size for an area of [width] x [height]: both sides
// rounded down to even (NV12 needs that). False when the area is too small or
// too large for H.264.
bool EncodeSize(int width, int height, Size* out);

// Which part of a captured window frame goes where in the output frame.
struct CropPlan {
  // False: nothing of the area is on screen; the output frame is all black.
  bool visible = false;
  // True: the copy fills the whole output frame (no black borders).
  bool covers = false;
  // Source box in the captured frame texture (right and bottom exclusive).
  int src_left = 0;
  int src_top = 0;
  int src_right = 0;
  int src_bottom = 0;
  // Where the box lands in the output frame.
  int dst_x = 0;
  int dst_y = 0;
};

// [area]: the requested area in client coordinates; [output]: its encoded
// size (see EncodeSize). [client]: the client area size now. [client_x],
// [client_y]: where the client area starts in the captured frame. [frame]:
// the usable size of the captured frame. Parts of the area outside the client
// area or the frame stay black, the rest keeps its place in the output.
CropPlan PlanCrop(const Rect& area, const Size& output, const Size& client,
                  int client_x, int client_y, const Size& frame);

// Offset of the client area inside a captured window frame along one axis:
// [client_screen] from ClientToScreen, [frame_screen] from
// DWMWA_EXTENDED_FRAME_BOUNDS. Never negative.
int ClientOffset(int client_screen, int frame_screen);

// A QueryPerformanceCounter value in 100 ns units, without overflow.
int64_t TicksTo100ns(int64_t ticks, int64_t frequency);

// The constant frame rate clock of a recording. Frame [index] is due at
// start + index / fps seconds and is stamped index / fps in the file.
class FramePacer {
 public:
  FramePacer() = default;
  FramePacer(int fps, int64_t frequency, int64_t start);

  // QPC ticks at which frame [index] is due.
  int64_t DueAt(int64_t index) const;
  // The last frame index due at [now] (QPC ticks); 0 before the start.
  int64_t IndexAt(int64_t now) const;
  // Presentation time of frame [index] in 100 ns units.
  int64_t SampleTime(int64_t index) const;

 private:
  int64_t fps_ = 30;
  int64_t frequency_ = 1;
  int64_t start_ = 0;
};

// Places audio packets on the recording's timeline (frame 0 = the start of
// the recording) so the track has no holes and no overlaps: a packet that
// arrives later than the timeline end gets silence in front of it, one that
// overlaps it loses its start.
class AudioTimeline {
 public:
  struct Placement {
    // Silent frames to write before the packet.
    int64_t silence = 0;
    // Frames to drop from the start of the packet.
    int64_t skip = 0;
  };

  // [tolerance]: how far (100 ns) a packet may sit off the timeline end
  // before it is moved.
  AudioTimeline(int sample_rate, int64_t tolerance);

  // A packet of [frames] frames captured at [time] (100 ns since the start).
  Placement Place(int64_t time, int64_t frames);
  // Extends the timeline with silence up to [time]; returns the frames added.
  int64_t FillTo(int64_t time);

  // Frames on the timeline so far.
  int64_t frames() const { return frames_; }
  // Time of frame [frame] in 100 ns units.
  int64_t TimeOf(int64_t frame) const;

 private:
  int64_t FramesIn(int64_t duration) const;

  int64_t rate_;
  int64_t tolerance_;
  int64_t frames_ = 0;
};

// Average H.264 bit rate (bits per second) for the frame size and rate.
uint32_t VideoBitrate(int width, int height, int fps);

// When a recording stops by itself: [max_seconds] (the user's limit, which
// the Dart side enforces) plus 30 s, or 4 hours when there is no limit.
int64_t SafetyCapSeconds(int64_t max_seconds);

// The CF_HDROP payload: a DROPFILES header followed by the wide paths, each
// null-terminated, and one more null. Empty paths are left out.
std::vector<uint8_t> BuildDropFiles(const std::vector<std::wstring>& paths);

// A CreateProcess command line that CommandLineToArgvW (which the runner's
// GetCommandLineArguments uses) splits back into [program] and [arguments]
// exactly: arguments with spaces, quotes or backslashes, and empty ones.
std::wstring BuildCommandLine(const std::wstring& program,
                              const std::vector<std::wstring>& arguments);

}  // namespace capture

#endif  // RUNNER_CAPTURE_UTIL_H_
