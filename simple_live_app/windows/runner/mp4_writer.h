#ifndef RUNNER_MP4_WRITER_H_
#define RUNNER_MP4_WRITER_H_

#include <d3d11.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <windows.h>
#include <wrl/client.h>

#include <cstdint>
#include <mutex>
#include <string>

// An MP4 file written by a Media Foundation sink writer: H.264 video from
// BGRA Direct3D 11 textures, optionally AAC audio from 16-bit stereo PCM at
// kAudioRate. Video and audio may be written from different threads.
class Mp4Writer {
 public:
  static constexpr int kAudioRate = 48000;
  static constexpr int kAudioChannels = 2;
  static constexpr int kAudioFrameBytes = 4;  // 16-bit stereo

  struct Config {
    std::wstring path;
    int width = 0;
    int height = 0;
    int fps = 30;
    bool audio = false;
  };

  Mp4Writer();
  ~Mp4Writer();
  Mp4Writer(const Mp4Writer&) = delete;
  Mp4Writer& operator=(const Mp4Writer&) = delete;

  // Creates the file and the encoders. [hardware]: the writer gets [manager]
  // and may use GPU transforms (a hardware encoder if there is one), frames
  // go in as GPU textures; otherwise they are copied to system memory and a
  // software encoder takes them. On failure the writer is closed again; the
  // caller removes the file.
  HRESULT Open(const Config& config, ID3D11Device* device,
               IMFDXGIDeviceManager* manager, bool hardware);

  // Writes [frame] (BGRA, the configured size) as one video frame.
  // S_FALSE: dropped because the encoder still holds all frame buffers.
  HRESULT WriteVideo(ID3D11Texture2D* frame, int64_t time, int64_t duration);

  // Writes [frames] frames of PCM; [data] null writes silence.
  HRESULT WriteAudio(const BYTE* data, uint32_t frames, int64_t time,
                     int64_t duration);

  // Finishes the file (writes the index). The writer is closed afterwards.
  HRESULT Finalize();

  // Closes the writer without finishing the file.
  void Abort();

  bool is_open() const { return writer_ != nullptr; }
  bool gpu_input() const { return gpu_input_; }
  bool has_audio() const { return audio_; }
  // Whether Media Foundation picked a hardware H.264 encoder.
  bool hardware_encoder() const { return hardware_encoder_; }

 private:
  HRESULT AddVideoStream();
  HRESULT AddAudioStream();
  void ConfigureEncoder();
  void DetectEncoder();
  HRESULT CreateGpuSample(ID3D11Texture2D* frame, IMFSample** sample);
  HRESULT CreateMemorySample(ID3D11Texture2D* frame, IMFSample** sample);

  Config config_;
  bool gpu_input_ = false;
  bool audio_ = false;
  bool hardware_encoder_ = false;

  Microsoft::WRL::ComPtr<ID3D11Device> device_;
  Microsoft::WRL::ComPtr<ID3D11DeviceContext> context_;
  Microsoft::WRL::ComPtr<IMFDXGIDeviceManager> manager_;
  // Guards writer_ calls (video and audio come from different threads).
  std::mutex mutex_;
  Microsoft::WRL::ComPtr<IMFSinkWriter> writer_;
  DWORD video_stream_ = 0;
  DWORD audio_stream_ = 0;
  Microsoft::WRL::ComPtr<IMFMediaType> video_input_;
  // GPU input: frame textures the encoder hands back when it is done.
  Microsoft::WRL::ComPtr<IMFVideoSampleAllocatorEx> allocator_;
  // System memory input: where frames are read back from the GPU.
  Microsoft::WRL::ComPtr<ID3D11Texture2D> staging_;
};

#endif  // RUNNER_MP4_WRITER_H_
