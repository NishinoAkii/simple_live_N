#include "capture_util.h"

#include <windows.h>
#include <shlobj.h>

#include <algorithm>
#include <cstring>

namespace capture {

namespace {

constexpr int64_t k100nsPerSecond = 10'000'000;

// floor(value * numerator / denominator) for value >= 0 without overflow
// as long as numerator * denominator fits.
int64_t MulDiv64(int64_t value, int64_t numerator, int64_t denominator) {
  return (value / denominator) * numerator +
         (value % denominator) * numerator / denominator;
}

}  // namespace

bool EncodeSize(int width, int height, Size* out) {
  if (width < kMinEncodeSide || height < kMinEncodeSide) {
    return false;
  }
  const int even_width = width & ~1;
  const int even_height = height & ~1;
  if (even_width > kMaxEncodeSide || even_height > kMaxEncodeSide) {
    return false;
  }
  const int64_t macroblocks = static_cast<int64_t>((even_width + 15) / 16) *
                              ((even_height + 15) / 16);
  if (macroblocks > kMaxEncodeMacroblocks) {
    return false;
  }
  out->width = even_width;
  out->height = even_height;
  return true;
}

CropPlan PlanCrop(const Rect& area, const Size& output, const Size& client,
                  int client_x, int client_y, const Size& frame) {
  CropPlan plan;
  const int left = std::max(area.x, 0);
  const int top = std::max(area.y, 0);
  const int right = std::min(
      {area.x + output.width, client.width, frame.width - client_x});
  const int bottom = std::min(
      {area.y + output.height, client.height, frame.height - client_y});
  if (client_x < 0 || client_y < 0 || left >= right || top >= bottom) {
    return plan;
  }
  plan.visible = true;
  plan.src_left = client_x + left;
  plan.src_top = client_y + top;
  plan.src_right = client_x + right;
  plan.src_bottom = client_y + bottom;
  plan.dst_x = left - area.x;
  plan.dst_y = top - area.y;
  plan.covers = left == area.x && top == area.y &&
                right == area.x + output.width &&
                bottom == area.y + output.height;
  return plan;
}

int ClientOffset(int client_screen, int frame_screen) {
  return client_screen > frame_screen ? client_screen - frame_screen : 0;
}

int64_t TicksTo100ns(int64_t ticks, int64_t frequency) {
  if (frequency <= 0) {
    return 0;
  }
  if (ticks < 0) {
    return -MulDiv64(-ticks, k100nsPerSecond, frequency);
  }
  return MulDiv64(ticks, k100nsPerSecond, frequency);
}

FramePacer::FramePacer(int fps, int64_t frequency, int64_t start)
    : fps_(fps > 0 ? fps : 1),
      frequency_(frequency > 0 ? frequency : 1),
      start_(start) {}

int64_t FramePacer::DueAt(int64_t index) const {
  return start_ + MulDiv64(index, frequency_, fps_);
}

int64_t FramePacer::IndexAt(int64_t now) const {
  if (now <= start_) {
    return 0;
  }
  return MulDiv64(now - start_, fps_, frequency_);
}

int64_t FramePacer::SampleTime(int64_t index) const {
  return MulDiv64(index, k100nsPerSecond, fps_);
}

AudioTimeline::AudioTimeline(int sample_rate, int64_t tolerance)
    : rate_(sample_rate > 0 ? sample_rate : 48000),
      tolerance_(tolerance > 0 ? tolerance : 0) {}

AudioTimeline::Placement AudioTimeline::Place(int64_t time, int64_t frames) {
  Placement placement;
  if (frames <= 0) {
    return placement;
  }
  const int64_t delta = time - TimeOf(frames_);
  if (delta > tolerance_) {
    placement.silence = FramesIn(delta);
  } else if (delta < -tolerance_) {
    placement.skip = std::min(frames, FramesIn(-delta));
  }
  frames_ += placement.silence + frames - placement.skip;
  return placement;
}

int64_t AudioTimeline::FillTo(int64_t time) {
  const int64_t end = TimeOf(frames_);
  if (time <= end) {
    return 0;
  }
  const int64_t added = FramesIn(time - end);
  frames_ += added;
  return added;
}

int64_t AudioTimeline::TimeOf(int64_t frame) const {
  return MulDiv64(frame, k100nsPerSecond, rate_);
}

int64_t AudioTimeline::FramesIn(int64_t duration) const {
  return duration <= 0 ? 0 : MulDiv64(duration, rate_, k100nsPerSecond);
}

uint32_t VideoBitrate(int width, int height, int fps) {
  // About 0.12 bits per pixel: 1080p30 gets 7.5 Mbit/s, 1080p60 15 Mbit/s.
  const int64_t bits =
      static_cast<int64_t>(width) * height * std::max(fps, 1) * 3 / 25;
  return static_cast<uint32_t>(
      std::clamp<int64_t>(bits, 1'500'000, 60'000'000));
}

int64_t SafetyCapSeconds(int64_t max_seconds) {
  return max_seconds > 0 ? max_seconds + 30 : 4 * 3600;
}

std::vector<uint8_t> BuildDropFiles(const std::vector<std::wstring>& paths) {
  size_t chars = 1;  // the final null
  for (const auto& path : paths) {
    if (!path.empty()) {
      chars += path.size() + 1;
    }
  }
  std::vector<uint8_t> bytes(sizeof(DROPFILES) + chars * sizeof(wchar_t), 0);
  auto* header = reinterpret_cast<DROPFILES*>(bytes.data());
  header->pFiles = sizeof(DROPFILES);
  header->fWide = TRUE;
  auto* out = reinterpret_cast<wchar_t*>(bytes.data() + sizeof(DROPFILES));
  for (const auto& path : paths) {
    if (path.empty()) {
      continue;
    }
    std::memcpy(out, path.data(), path.size() * sizeof(wchar_t));
    out += path.size() + 1;  // the null is already there
  }
  return bytes;
}

namespace {

// Backslashes count only right before a quote: 2n backslashes + quote is n
// backslashes and the quote ends; 2n + 1 backslashes + quote is n
// backslashes and a literal quote.
void AppendQuotedArgument(const std::wstring& argument, std::wstring* line) {
  if (!argument.empty() &&
      argument.find_first_of(L" \t\n\v\"") == std::wstring::npos) {
    line->append(argument);
    return;
  }
  line->push_back(L'"');
  for (size_t i = 0;; ++i) {
    size_t backslashes = 0;
    while (i < argument.size() && argument[i] == L'\\') {
      ++i;
      ++backslashes;
    }
    if (i == argument.size()) {
      // Before the closing quote: all of them doubled.
      line->append(backslashes * 2, L'\\');
      break;
    }
    if (argument[i] == L'"') {
      line->append(backslashes * 2 + 1, L'\\');
      line->push_back(L'"');
    } else {
      line->append(backslashes, L'\\');
      line->push_back(argument[i]);
    }
  }
  line->push_back(L'"');
}

}  // namespace

std::wstring BuildCommandLine(const std::wstring& program,
                              const std::vector<std::wstring>& arguments) {
  // The program name is read up to the next quote; paths have no quotes.
  std::wstring line = L"\"" + program + L"\"";
  for (const auto& argument : arguments) {
    line.push_back(L' ');
    AppendQuotedArgument(argument, &line);
  }
  return line;
}

}  // namespace capture
