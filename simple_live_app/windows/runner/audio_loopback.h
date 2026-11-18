#ifndef RUNNER_AUDIO_LOOPBACK_H_
#define RUNNER_AUDIO_LOOPBACK_H_

#include <audioclient.h>
#include <windows.h>
#include <wrl/client.h>

#include <cstdint>
#include <functional>
#include <string>

// What this process plays, captured through WASAPI process loopback as 48 kHz
// 16-bit stereo PCM. The loopback covers the process tree: child processes
// started by this one are heard too.
class AudioLoopback {
 public:
  // [data] is null for a silent packet. [time] is the QPC time (100 ns) of
  // the first frame, 0 when the device gave none.
  using PacketSink =
      std::function<void(const BYTE* data, uint32_t frames, int64_t time)>;

  // First Windows build with process loopback (Windows 11; Server 2022).
  static constexpr DWORD kMinBuild = 20348;

  AudioLoopback();
  ~AudioLoopback();
  AudioLoopback(const AudioLoopback&) = delete;
  AudioLoopback& operator=(const AudioLoopback&) = delete;

  // Activates and sets up the loopback client. Returns an empty string on
  // success, otherwise a short reason. Call on an MTA thread.
  std::string Open();

  HRESULT Start();
  HRESULT Stop();

  // Signalled when packets are ready.
  HANDLE event() const { return event_; }

  // Hands every packet captured so far to [sink].
  HRESULT Drain(const PacketSink& sink);

 private:
  Microsoft::WRL::ComPtr<IAudioClient> client_;
  Microsoft::WRL::ComPtr<IAudioCaptureClient> capture_;
  HANDLE event_ = nullptr;
  bool started_ = false;
};

#endif  // RUNNER_AUDIO_LOOPBACK_H_
