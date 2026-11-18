#include "screen_recorder.h"

#include <d3d10_1.h>  // ID3D10Multithread; d3d10.h alone clashes with d3d11.h
#include <d3d11_4.h>
#include <dwmapi.h>
#include <dxgi1_2.h>
#include <hstring.h>
#include <inspectable.h>
#include <mfapi.h>
#include <windows.foundation.h>
#include <windows.graphics.capture.h>
#include <windows.graphics.capture.interop.h>
#include <windows.graphics.directx.direct3d11.interop.h>
#include <wrl/client.h>

#include <algorithm>
#include <atomic>
#include <cstdio>
#include <cwchar>
#include <thread>
#include <vector>

#include "audio_loopback.h"
#include "mp4_writer.h"

// How
//
// Video: Windows.Graphics.Capture on this window (through the WinRT ABI, the
// runner builds without C++ exceptions, which C++/WinRT needs). The frame pool
// is free-threaded and polled: the recorder's thread wakes at each frame time
// (a high-resolution waitable timer on the QPC clock), takes the newest
// captured frame if there is one, copies the requested part of the client
// area into a canvas texture of the output size (CopySubresourceRegion; the
// rest black) and hands the canvas to the sink writer. No new frame (static
// content, window minimized) means the canvas is written again, a late wake
// skips frame times; so the file has a constant frame rate and stays in step
// with the clock.
//
// Direct3D: the recorder's own device, on the adapter that drives the
// window's monitor, with multithread protection (Media Foundation uses it from
// its own threads). Flutter's and mpv's devices are never touched.
//
// Encoding: a Media Foundation sink writer with the device manager and
// hardware transforms: BGRA textures go in, Media Foundation converts them on
// the GPU and picks a hardware H.264 encoder when there is one. If that setup
// or the first frame fails, the file is started over with frames read back to
// system memory and the software encoder.
//
// Audio: WASAPI process loopback (Windows 11) on its own thread, AAC in the
// same file. Every packet is placed on the recording's timeline by its QPC
// time (the clock the video frames are timed by); gaps are filled with
// silence, so the sound track is continuous and as long as the video.

namespace {

using Microsoft::WRL::ComPtr;
namespace wf = ABI::Windows::Foundation;
namespace wg = ABI::Windows::Graphics;
namespace wgc = ABI::Windows::Graphics::Capture;
namespace wgd = ABI::Windows::Graphics::DirectX;
namespace wd3d = ABI::Windows::Graphics::DirectX::Direct3D11;

// Windows 10 1903: capture of a window by its HWND.
constexpr DWORD kMinCaptureBuild = 18362;
constexpr wgd::DirectXPixelFormat kPixelFormat =
    wgd::DirectXPixelFormat_B8G8R8A8UIntNormalized;
constexpr INT32 kPoolBuffers = 2;
// An audio packet may be this far (100 ns) off the timeline before silence
// is put in front of it or its start is dropped.
constexpr int64_t kAudioTolerance = 400'000;  // 40 ms
// With no packets for this long, the sound track is filled with silence.
constexpr int64_t kAudioIdleMargin = 2'500'000;  // 250 ms
constexpr DWORD kAudioWakeMs = 50;
constexpr int64_t kSilenceChunkFrames = Mp4Writer::kAudioRate / 10;
// Upper bound of the automatic stop, whatever Dart asks for.
constexpr int64_t kMaxCapSeconds = 7 * 24 * 3600;

std::string HrText(const char* what, HRESULT hr) {
  char text[128];
  std::snprintf(text, sizeof(text), "%s (0x%08lX)", what,
                static_cast<unsigned long>(hr));
  return text;
}

DWORD WindowsBuild() {
  using RtlGetVersionFn = LONG(WINAPI*)(RTL_OSVERSIONINFOW*);
  const HMODULE ntdll = ::GetModuleHandleW(L"ntdll.dll");
  const auto get_version =
      ntdll == nullptr ? nullptr
                       : reinterpret_cast<RtlGetVersionFn>(
                             ::GetProcAddress(ntdll, "RtlGetVersion"));
  RTL_OSVERSIONINFOW info = {};
  info.dwOSVersionInfoSize = sizeof(info);
  return get_version != nullptr && get_version(&info) == 0
             ? info.dwBuildNumber
             : 0;
}

int64_t Qpc() {
  LARGE_INTEGER value;
  ::QueryPerformanceCounter(&value);
  return value.QuadPart;
}

// RoGetActivationFactory, looked up at run time: the exe keeps no import
// that older Windows lacks.
HRESULT GetActivationFactory(const wchar_t* class_name, REFIID iid,
                             void** factory) {
  using GetFactoryFn = HRESULT(WINAPI*)(HSTRING, REFIID, void**);
  using StringReferenceFn =
      HRESULT(WINAPI*)(PCWSTR, UINT32, HSTRING_HEADER*, HSTRING*);
  static const HMODULE combase =
      ::LoadLibraryExW(L"combase.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
  static const auto get_factory =
      combase == nullptr ? nullptr
                         : reinterpret_cast<GetFactoryFn>(::GetProcAddress(
                               combase, "RoGetActivationFactory"));
  static const auto make_reference =
      combase == nullptr
          ? nullptr
          : reinterpret_cast<StringReferenceFn>(
                ::GetProcAddress(combase, "WindowsCreateStringReference"));
  if (get_factory == nullptr || make_reference == nullptr) {
    return E_NOTIMPL;
  }
  HSTRING_HEADER header = {};
  HSTRING name = nullptr;
  HRESULT hr = make_reference(
      class_name, static_cast<UINT32>(std::wcslen(class_name)), &header, &name);
  if (SUCCEEDED(hr)) {
    hr = get_factory(name, iid, factory);
  }
  return hr;
}

HRESULT CreateWinRtDevice(IDXGIDevice* device, IInspectable** result) {
  using CreateFn = HRESULT(WINAPI*)(IDXGIDevice*, IInspectable**);
  static const HMODULE d3d11 = ::GetModuleHandleW(L"d3d11.dll");
  static const auto create =
      d3d11 == nullptr
          ? nullptr
          : reinterpret_cast<CreateFn>(::GetProcAddress(
                d3d11, "CreateDirect3D11DeviceFromDXGIDevice"));
  return create == nullptr ? E_NOTIMPL : create(device, result);
}

void CloseWinRt(IUnknown* object) {
  ComPtr<wf::IClosable> closable;
  if (object != nullptr &&
      SUCCEEDED(object->QueryInterface(IID_PPV_ARGS(&closable)))) {
    closable->Close();
  }
}

HRESULT SurfaceTexture(wd3d::IDirect3DSurface* surface,
                       ID3D11Texture2D** texture) {
  ComPtr<::Windows::Graphics::DirectX::Direct3D11::IDirect3DDxgiInterfaceAccess>
      access;
  HRESULT hr = surface->QueryInterface(IID_PPV_ARGS(&access));
  if (SUCCEEDED(hr)) {
    hr = access->GetInterface(IID_PPV_ARGS(texture));
  }
  return hr;
}

// The adapter whose output shows [window], so frames need no copy between
// GPUs. Null when none matches (the default adapter is used then).
ComPtr<IDXGIAdapter1> AdapterForWindow(HWND window) {
  const HMONITOR monitor = ::MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST);
  ComPtr<IDXGIFactory1> factory;
  if (FAILED(::CreateDXGIFactory1(IID_PPV_ARGS(&factory)))) {
    return nullptr;
  }
  for (UINT a = 0; a < 16; ++a) {
    ComPtr<IDXGIAdapter1> adapter;
    if (FAILED(factory->EnumAdapters1(a, &adapter))) {
      break;
    }
    for (UINT o = 0; o < 16; ++o) {
      ComPtr<IDXGIOutput> output;
      if (FAILED(adapter->EnumOutputs(o, &output))) {
        break;
      }
      DXGI_OUTPUT_DESC desc = {};
      if (SUCCEEDED(output->GetDesc(&desc)) && desc.Monitor == monitor) {
        return adapter;
      }
    }
  }
  return nullptr;
}

void Protect(ID3D11Device* device) {
  ComPtr<ID3D11DeviceContext> context;
  device->GetImmediateContext(&context);
  ComPtr<ID3D11Multithread> multithread;
  if (context && SUCCEEDED(context.As(&multithread))) {
    multithread->SetMultithreadProtected(TRUE);
    return;
  }
  ComPtr<ID3D10Multithread> legacy;
  if (SUCCEEDED(device->QueryInterface(IID_PPV_ARGS(&legacy)))) {
    legacy->SetMultithreadProtected(TRUE);
  }
}

// Size of the client area and where it starts in a captured frame of the
// window. False while the window is minimized or has no client area.
bool ClientGeometry(HWND window, capture::Size* client, int* client_x,
                    int* client_y) {
  RECT client_rect = {};
  RECT bounds = {};
  POINT origin = {0, 0};
  if (::IsIconic(window) || !::GetClientRect(window, &client_rect) ||
      !::ClientToScreen(window, &origin) ||
      FAILED(::DwmGetWindowAttribute(window, DWMWA_EXTENDED_FRAME_BOUNDS,
                                     &bounds, sizeof(bounds)))) {
    return false;
  }
  client->width = client_rect.right - client_rect.left;
  client->height = client_rect.bottom - client_rect.top;
  *client_x = capture::ClientOffset(origin.x, bounds.left);
  *client_y = capture::ClientOffset(origin.y, bounds.top);
  return client->width > 0 && client->height > 0;
}

const char* ReasonName(StopReason reason) {
  switch (reason) {
    case StopReason::kWindowClosed:
      return "closed";
    case StopReason::kLimit:
      return "limit";
    case StopReason::kError:
      return "error";
    case StopReason::kNone:
    case StopReason::kRequested:
      break;
  }
  return "stopped";
}

class Recorder final : public ScreenRecorder {
 public:
  Recorder(HWND window, RecordOptions options, EventCallback on_event)
      : window_(window),
        options_(std::move(options)),
        on_event_(std::move(on_event)),
        stop_event_(::CreateEventW(nullptr, TRUE, FALSE, nullptr)),
        done_event_(::CreateEventW(nullptr, TRUE, FALSE, nullptr)),
        audio_stop_(::CreateEventW(nullptr, TRUE, FALSE, nullptr)) {}

  ~Recorder() override {
    if (thread_.joinable()) {
      RequestStop(StopReason::kRequested);
      thread_.join();
    }
    for (HANDLE handle : {stop_event_, done_event_, audio_stop_}) {
      if (handle != nullptr) {
        ::CloseHandle(handle);
      }
    }
  }

  void Start() override {
    thread_ = std::thread([this] { Run(); });
  }

  void RequestStop(StopReason reason) override {
    int expected = static_cast<int>(StopReason::kNone);
    stop_reason_.compare_exchange_strong(expected, static_cast<int>(reason));
    ::SetEvent(stop_event_);
  }

  bool Wait(DWORD timeout_ms) override {
    if (!thread_.joinable()) {
      return true;
    }
    if (::WaitForSingleObject(done_event_, timeout_ms) != WAIT_OBJECT_0) {
      return false;
    }
    thread_.join();
    return true;
  }

  void Detach() override {
    if (thread_.joinable()) {
      thread_.detach();
    }
  }

 private:
  void Run();
  bool Init(std::string* code, std::string* message);
  HRESULT CreateDevice();
  bool CreateCapture(std::string* code, std::string* message);
  void AllowBorderless();
  HRESULT CreateCanvas();
  void ClearCanvas();
  HRESULT OpenWriter(bool gpu_input);
  void Record();
  void UpdateCanvas();
  RecordSummary Finish();
  void Release();
  void AudioThread();
  void DrainAudio();
  void WriteAudioFrames(const BYTE* data, int64_t first, int64_t count);
  void WriteSilence(int64_t first, int64_t count);
  // 100 ns since the recording started.
  int64_t Now() const {
    return capture::TicksTo100ns(Qpc(), frequency_) - start_100ns_;
  }
  void Emit(RecorderEvent event) {
    if (on_event_) {
      on_event_(std::move(event));
    }
  }

  const HWND window_;
  const RecordOptions options_;
  const EventCallback on_event_;
  std::thread thread_;
  const HANDLE stop_event_;
  const HANDLE done_event_;
  std::atomic<int> stop_reason_{static_cast<int>(StopReason::kNone)};

  // Used by the recorder's thread only; the audio thread uses writer_,
  // timeline_ and audio_ while it runs.
  DWORD build_ = 0;
  capture::Size output_;
  ComPtr<ID3D11Device> device_;
  ComPtr<ID3D11DeviceContext> context_;
  ComPtr<IMFDXGIDeviceManager> manager_;
  ComPtr<wd3d::IDirect3DDevice> winrt_device_;
  ComPtr<wgc::IGraphicsCaptureItem> item_;
  ComPtr<wgc::IDirect3D11CaptureFramePool> pool_;
  ComPtr<wgc::IGraphicsCaptureSession> session_;
  wg::SizeInt32 pool_size_ = {};
  ComPtr<ID3D11Texture2D> canvas_;
  ComPtr<ID3D11RenderTargetView> canvas_view_;
  Mp4Writer writer_;
  std::unique_ptr<AudioLoopback> audio_;
  bool audio_live_ = false;
  std::string audio_note_;
  std::thread audio_thread_;
  const HANDLE audio_stop_;
  std::atomic<bool> audio_lost_{false};
  capture::AudioTimeline timeline_{Mp4Writer::kAudioRate, kAudioTolerance};
  capture::FramePacer pacer_;
  int64_t frequency_ = 1;
  int64_t start_ticks_ = 0;
  int64_t start_100ns_ = 0;
  int64_t frames_written_ = 0;
  int64_t dropped_ = 0;
  // One past the last frame index written.
  int64_t end_index_ = 0;
  // What ended the recording with StopReason::kError.
  std::string error_;
};

void Recorder::Run() {
  const bool com = SUCCEEDED(::CoInitializeEx(nullptr, COINIT_MULTITHREADED));
  const bool media = SUCCEEDED(::MFStartup(MF_VERSION, MFSTARTUP_LITE));
  std::string code;
  std::string message;
  bool started = false;
  if (!media) {
    code = "unsupported";
    message = "Media Foundation is not available";
  } else {
    started = Init(&code, &message);
  }
  RecordSummary summary;
  if (started) {
    Emit(RecorderEvent{RecorderEvent::Kind::kStarted, "", "", {}});
    Record();
    summary = Finish();
  }
  Release();
  if (media) {
    ::MFShutdown();
  }
  if (com) {
    ::CoUninitialize();
  }
  if (started) {
    Emit(RecorderEvent{RecorderEvent::Kind::kFinished, "", "", summary});
  } else {
    Emit(RecorderEvent{RecorderEvent::Kind::kStarted, code, message, {}});
  }
  ::SetEvent(done_event_);
}

bool Recorder::Init(std::string* code, std::string* message) {
  build_ = WindowsBuild();
  if (build_ != 0 && build_ < kMinCaptureBuild) {
    *code = "unsupported";
    *message = "recording needs Windows 10 1903 or later";
    return false;
  }
  if (stop_event_ == nullptr || done_event_ == nullptr ||
      audio_stop_ == nullptr) {
    *code = "start_failed";
    *message = "out of system resources";
    return false;
  }
  if (!capture::EncodeSize(options_.area.width, options_.area.height,
                           &output_)) {
    *code = "unsupported";
    *message = "area size not supported (16 to 4096 px, at most 4096x2304)";
    return false;
  }
  if (!::IsWindow(window_)) {
    *code = "start_failed";
    *message = "the window is gone";
    return false;
  }
  HRESULT hr = CreateDevice();
  if (FAILED(hr)) {
    *code = "start_failed";
    *message = HrText("no Direct3D 11 device", hr);
    return false;
  }
  if (!CreateCapture(code, message)) {
    return false;
  }
  hr = CreateCanvas();
  if (FAILED(hr)) {
    *code = "start_failed";
    *message = HrText("no frame buffer", hr);
    return false;
  }
  if (options_.audio) {
    if (build_ != 0 && build_ < AudioLoopback::kMinBuild) {
      audio_note_ = "recording the app's sound needs Windows 11";
    } else {
      audio_ = std::make_unique<AudioLoopback>();
      audio_note_ = audio_->Open();
      if (!audio_note_.empty()) {
        audio_.reset();
      }
    }
  }
  hr = OpenWriter(true);
  if (FAILED(hr)) {
    hr = OpenWriter(false);
  }
  if (FAILED(hr)) {
    *code = "start_failed";
    *message = HrText("could not create the video file", hr);
    return false;
  }
  hr = session_->StartCapture();
  if (FAILED(hr)) {
    *code = "start_failed";
    *message = HrText("window capture did not start", hr);
    return false;
  }
  return true;
}

HRESULT Recorder::CreateDevice() {
  static const D3D_FEATURE_LEVEL kLevels[] = {
      D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0, D3D_FEATURE_LEVEL_10_1,
      D3D_FEATURE_LEVEL_10_0};
  const ComPtr<IDXGIAdapter1> adapter = AdapterForWindow(window_);
  std::vector<IDXGIAdapter*> candidates;
  if (adapter) {
    candidates.push_back(adapter.Get());
  }
  candidates.push_back(nullptr);
  const UINT base = D3D11_CREATE_DEVICE_BGRA_SUPPORT;
  HRESULT hr = E_FAIL;
  for (IDXGIAdapter* candidate : candidates) {
    for (const UINT flags : {base | D3D11_CREATE_DEVICE_VIDEO_SUPPORT, base}) {
      device_.Reset();
      context_.Reset();
      hr = ::D3D11CreateDevice(
          candidate,
          candidate == nullptr ? D3D_DRIVER_TYPE_HARDWARE
                               : D3D_DRIVER_TYPE_UNKNOWN,
          nullptr, flags, kLevels, ARRAYSIZE(kLevels), D3D11_SDK_VERSION,
          &device_, nullptr, &context_);
      if (SUCCEEDED(hr)) {
        break;
      }
    }
    if (SUCCEEDED(hr)) {
      break;
    }
  }
  if (FAILED(hr)) {
    return hr;
  }
  Protect(device_.Get());
  // Without a device manager the writer can only take frames from system
  // memory (OpenWriter falls back to that), so a failure here is not fatal.
  UINT token = 0;
  if (FAILED(::MFCreateDXGIDeviceManager(&token, &manager_)) ||
      FAILED(manager_->ResetDevice(device_.Get(), token))) {
    manager_.Reset();
  }
  ComPtr<IDXGIDevice> dxgi_device;
  hr = device_.As(&dxgi_device);
  ComPtr<IInspectable> inspectable;
  if (SUCCEEDED(hr)) {
    hr = CreateWinRtDevice(dxgi_device.Get(), &inspectable);
  }
  if (SUCCEEDED(hr)) {
    hr = inspectable.As(&winrt_device_);
  }
  return hr;
}

bool Recorder::CreateCapture(std::string* code, std::string* message) {
  ComPtr<wgc::IGraphicsCaptureSessionStatics> session_statics;
  HRESULT hr = GetActivationFactory(
      RuntimeClass_Windows_Graphics_Capture_GraphicsCaptureSession,
      IID_PPV_ARGS(&session_statics));
  boolean supported = false;
  if (SUCCEEDED(hr)) {
    hr = session_statics->IsSupported(&supported);
  }
  if (FAILED(hr) || !supported) {
    *code = "unsupported";
    *message = "window capture is not supported on this system";
    return false;
  }
  ComPtr<IGraphicsCaptureItemInterop> interop;
  hr = GetActivationFactory(
      RuntimeClass_Windows_Graphics_Capture_GraphicsCaptureItem,
      IID_PPV_ARGS(&interop));
  if (SUCCEEDED(hr)) {
    hr = interop->CreateForWindow(window_, IID_PPV_ARGS(&item_));
  }
  wg::SizeInt32 size = {};
  if (SUCCEEDED(hr)) {
    hr = item_->get_Size(&size);
  }
  size.Width = std::max(size.Width, 1);
  size.Height = std::max(size.Height, 1);
  ComPtr<wgc::IDirect3D11CaptureFramePoolStatics2> pool_statics;
  if (SUCCEEDED(hr)) {
    hr = GetActivationFactory(
        RuntimeClass_Windows_Graphics_Capture_Direct3D11CaptureFramePool,
        IID_PPV_ARGS(&pool_statics));
  }
  if (SUCCEEDED(hr)) {
    hr = pool_statics->CreateFreeThreaded(winrt_device_.Get(), kPixelFormat,
                                          kPoolBuffers, size, &pool_);
  }
  if (SUCCEEDED(hr)) {
    pool_size_ = size;
    hr = pool_->CreateCaptureSession(item_.Get(), &session_);
  }
  if (FAILED(hr)) {
    *code = "start_failed";
    *message = HrText("window capture failed", hr);
    return false;
  }
  // Windows 10 2004 and later: leave the mouse pointer out.
  ComPtr<wgc::IGraphicsCaptureSession2> session2;
  if (SUCCEEDED(session_.As(&session2))) {
    session2->put_IsCursorCaptureEnabled(false);
  }
  // Windows 11: no yellow border around the window, if the user lets desktop
  // apps turn it off (Settings > Privacy > Screenshot borders).
  ComPtr<wgc::IGraphicsCaptureSession3> session3;
  if (SUCCEEDED(session_.As(&session3))) {
    AllowBorderless();
    session3->put_IsBorderRequired(false);
  }
  // Windows 11 24H2: no more frames than needed (high refresh rate screens).
  ComPtr<wgc::IGraphicsCaptureSession5> session5;
  if (SUCCEEDED(session_.As(&session5))) {
    wf::TimeSpan interval = {};
    interval.Duration = 10'000'000 / (static_cast<int64_t>(options_.fps) * 2);
    session5->put_MinUpdateInterval(interval);
  }
  return true;
}

void Recorder::AllowBorderless() {
  ComPtr<wgc::IGraphicsCaptureAccessStatics> access;
  if (FAILED(GetActivationFactory(
          RuntimeClass_Windows_Graphics_Capture_GraphicsCaptureAccess,
          IID_PPV_ARGS(&access)))) {
    return;
  }
  ComPtr<
      __FIAsyncOperation_1_Windows__CSecurity__CAuthorization__CAppCapabilityAccess__CAppCapabilityAccessStatus>
      operation;
  if (FAILED(access->RequestAccessAsync(
          wgc::GraphicsCaptureAccessKind_Borderless, &operation))) {
    return;
  }
  ComPtr<wf::IAsyncInfo> info;
  if (FAILED(operation.As(&info))) {
    return;
  }
  // Desktop apps get the answer right away (no prompt); wait at most 1 s.
  for (int i = 0; i < 100; ++i) {
    wf::AsyncStatus status = wf::AsyncStatus::Started;
    if (FAILED(info->get_Status(&status)) ||
        status != wf::AsyncStatus::Started) {
      return;
    }
    ::Sleep(10);
  }
}

HRESULT Recorder::CreateCanvas() {
  D3D11_TEXTURE2D_DESC desc = {};
  desc.Width = static_cast<UINT>(output_.width);
  desc.Height = static_cast<UINT>(output_.height);
  desc.MipLevels = 1;
  desc.ArraySize = 1;
  desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
  desc.SampleDesc.Count = 1;
  desc.Usage = D3D11_USAGE_DEFAULT;
  desc.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
  HRESULT hr = device_->CreateTexture2D(&desc, nullptr, &canvas_);
  if (SUCCEEDED(hr)) {
    hr = device_->CreateRenderTargetView(canvas_.Get(), nullptr,
                                         &canvas_view_);
  }
  if (SUCCEEDED(hr)) {
    ClearCanvas();
  }
  return hr;
}

void Recorder::ClearCanvas() {
  static const float kBlack[4] = {0.0f, 0.0f, 0.0f, 1.0f};
  context_->ClearRenderTargetView(canvas_view_.Get(), kBlack);
}

HRESULT Recorder::OpenWriter(bool gpu_input) {
  Mp4Writer::Config config;
  config.path = options_.path;
  config.width = output_.width;
  config.height = output_.height;
  config.fps = options_.fps;
  config.audio = options_.audio && audio_ != nullptr;
  const HRESULT hr =
      writer_.Open(config, device_.Get(), manager_.Get(), gpu_input);
  if (FAILED(hr)) {
    ::DeleteFileW(options_.path.c_str());
  }
  return hr;
}

void Recorder::Record() {
  LARGE_INTEGER value;
  ::QueryPerformanceFrequency(&value);
  frequency_ = value.QuadPart > 0 ? value.QuadPart : 1;
  start_ticks_ = Qpc();
  start_100ns_ = capture::TicksTo100ns(start_ticks_, frequency_);
  pacer_ = capture::FramePacer(options_.fps, frequency_, start_ticks_);
  const int64_t cap_ticks =
      std::min(capture::SafetyCapSeconds(options_.max_seconds),
               kMaxCapSeconds) *
      frequency_;
  if (audio_) {
    const HRESULT started = audio_->Start();
    audio_live_ = SUCCEEDED(started);
    if (!audio_live_) {
      audio_note_ = HrText("audio capture did not start", started);
      audio_.reset();
    }
  }

  HANDLE timer = ::CreateWaitableTimerExW(
      nullptr, nullptr, CREATE_WAITABLE_TIMER_HIGH_RESOLUTION,
      TIMER_ALL_ACCESS);
  if (timer == nullptr) {
    timer = ::CreateWaitableTimerExW(nullptr, nullptr, 0, TIMER_ALL_ACCESS);
  }
  StopReason reason = StopReason::kNone;
  bool restarted = false;
  int64_t index = 0;
  for (;;) {
    int64_t now = Qpc();
    const int64_t due = pacer_.DueAt(index);
    if (due > now && timer != nullptr) {
      LARGE_INTEGER wait;
      wait.QuadPart = -std::max<int64_t>(
          capture::TicksTo100ns(due - now, frequency_), 1);
      ::SetWaitableTimer(timer, &wait, 0, nullptr, nullptr, FALSE);
      const HANDLE handles[] = {stop_event_, timer};
      if (::WaitForMultipleObjects(2, handles, FALSE, INFINITE) ==
          WAIT_OBJECT_0) {
        break;
      }
    } else if (due > now) {
      const int64_t ms = (due - now) * 1000 / frequency_ + 1;
      if (::WaitForSingleObject(stop_event_, static_cast<DWORD>(ms)) ==
          WAIT_OBJECT_0) {
        break;
      }
    } else if (::WaitForSingleObject(stop_event_, 0) == WAIT_OBJECT_0) {
      break;
    }
    now = Qpc();
    if (now - start_ticks_ >= cap_ticks) {
      reason = StopReason::kLimit;
      break;
    }
    if (!::IsWindow(window_)) {
      reason = StopReason::kWindowClosed;
      break;
    }
    // Woken late (a busy system or a slow encoder): skip the missed frame
    // times rather than fall behind the clock.
    const int64_t due_index = pacer_.IndexAt(now);
    if (due_index > index) {
      dropped_ += due_index - index;
      index = due_index;
    }
    UpdateCanvas();
    const int64_t time = pacer_.SampleTime(index);
    const HRESULT hr = writer_.WriteVideo(
        canvas_.Get(), time, pacer_.SampleTime(index + 1) - time);
    if (hr == S_FALSE) {
      ++dropped_;
    } else if (FAILED(hr)) {
      if (frames_written_ == 0 && writer_.gpu_input() && !restarted) {
        // The GPU path took the setup but not the first frame: start the
        // file over with frames from system memory.
        restarted = true;
        writer_.Abort();
        ::DeleteFileW(options_.path.c_str());
        if (SUCCEEDED(OpenWriter(false))) {
          continue;
        }
      }
      error_ = HrText("writing the video failed", hr);
      reason = StopReason::kError;
      break;
    } else {
      ++frames_written_;
      end_index_ = index + 1;
      if (frames_written_ == 1 && writer_.has_audio()) {
        audio_thread_ = std::thread([this] { AudioThread(); });
      }
    }
    ++index;
  }
  if (timer != nullptr) {
    ::CloseHandle(timer);
  }
  if (reason != StopReason::kNone) {
    int expected = static_cast<int>(StopReason::kNone);
    stop_reason_.compare_exchange_strong(expected, static_cast<int>(reason));
  }
}

void Recorder::UpdateCanvas() {
  // Only the newest frame counts; older ones go back to the pool.
  ComPtr<wgc::IDirect3D11CaptureFrame> frame;
  for (int i = 0; i < 8; ++i) {
    ComPtr<wgc::IDirect3D11CaptureFrame> next;
    if (FAILED(pool_->TryGetNextFrame(&next)) || !next) {
      break;
    }
    if (frame) {
      CloseWinRt(frame.Get());
    }
    frame = next;
  }
  if (!frame) {
    return;  // nothing new: the canvas keeps the last picture
  }
  wg::SizeInt32 content = {};
  frame->get_ContentSize(&content);
  {
    ComPtr<wd3d::IDirect3DSurface> surface;
    ComPtr<ID3D11Texture2D> texture;
    capture::Size client;
    int client_x = 0;
    int client_y = 0;
    if (SUCCEEDED(frame->get_Surface(&surface)) &&
        SUCCEEDED(SurfaceTexture(surface.Get(), &texture)) &&
        ClientGeometry(window_, &client, &client_x, &client_y)) {
      D3D11_TEXTURE2D_DESC desc = {};
      texture->GetDesc(&desc);
      capture::Size usable;
      usable.width = std::min(content.Width, static_cast<int>(desc.Width));
      usable.height = std::min(content.Height, static_cast<int>(desc.Height));
      const capture::CropPlan plan = capture::PlanCrop(
          options_.area, output_, client, client_x, client_y, usable);
      if (!plan.covers) {
        ClearCanvas();
      }
      if (plan.visible) {
        D3D11_BOX box = {};
        box.left = static_cast<UINT>(plan.src_left);
        box.top = static_cast<UINT>(plan.src_top);
        box.front = 0;
        box.right = static_cast<UINT>(plan.src_right);
        box.bottom = static_cast<UINT>(plan.src_bottom);
        box.back = 1;
        context_->CopySubresourceRegion(
            canvas_.Get(), 0, static_cast<UINT>(plan.dst_x),
            static_cast<UINT>(plan.dst_y), 0, texture.Get(), 0, &box);
      }
    }
  }
  CloseWinRt(frame.Get());
  if (content.Width > 0 && content.Height > 0 &&
      (content.Width != pool_size_.Width ||
       content.Height != pool_size_.Height)) {
    // The window changed size: buffers of the new size from now on. The
    // output frame keeps its size.
    if (SUCCEEDED(pool_->Recreate(winrt_device_.Get(), kPixelFormat,
                                  kPoolBuffers, content))) {
      pool_size_ = content;
    }
  }
}

void Recorder::AudioThread() {
  const bool com = SUCCEEDED(::CoInitializeEx(nullptr, COINIT_MULTITHREADED));
  for (;;) {
    DWORD woke = WAIT_TIMEOUT;
    if (audio_ && !audio_lost_) {
      const HANDLE handles[] = {audio_stop_, audio_->event()};
      woke = ::WaitForMultipleObjects(2, handles, FALSE, kAudioWakeMs);
      DrainAudio();
    } else {
      woke = ::WaitForSingleObject(audio_stop_, kAudioWakeMs);
    }
    if (woke == WAIT_OBJECT_0) {
      break;
    }
    // Nothing played for a while (paused, or no capture at all): silence,
    // so the sound track keeps up with the video.
    const int64_t first = timeline_.frames();
    const int64_t added = timeline_.FillTo(Now() - kAudioIdleMargin);
    if (added > 0) {
      WriteSilence(first, added);
    }
  }
  if (com) {
    ::CoUninitialize();
  }
}

void Recorder::DrainAudio() {
  const HRESULT hr = audio_->Drain(
      [this](const BYTE* data, uint32_t frames, int64_t time) {
        // A packet without a time is taken as just captured.
        const int64_t at = time != 0 ? time - start_100ns_
                                     : Now() - timeline_.TimeOf(frames);
        const int64_t first = timeline_.frames();
        const capture::AudioTimeline::Placement placement =
            timeline_.Place(at, frames);
        if (placement.silence > 0) {
          WriteSilence(first, placement.silence);
        }
        const int64_t kept = static_cast<int64_t>(frames) - placement.skip;
        if (kept > 0) {
          WriteAudioFrames(
              data == nullptr
                  ? nullptr
                  : data + placement.skip * Mp4Writer::kAudioFrameBytes,
              first + placement.silence, kept);
        }
      });
  if (FAILED(hr)) {
    // The rest of the track is silence (AudioThread fills it).
    audio_lost_ = true;
  }
}

void Recorder::WriteAudioFrames(const BYTE* data, int64_t first,
                                int64_t count) {
  const int64_t time = timeline_.TimeOf(first);
  writer_.WriteAudio(data, static_cast<uint32_t>(count), time,
                     timeline_.TimeOf(first + count) - time);
}

void Recorder::WriteSilence(int64_t first, int64_t count) {
  while (count > 0) {
    const int64_t chunk = std::min(count, kSilenceChunkFrames);
    WriteAudioFrames(nullptr, first, chunk);
    first += chunk;
    count -= chunk;
  }
}

RecordSummary Recorder::Finish() {
  RecordSummary summary;
  summary.path = options_.path_utf8;
  summary.width = output_.width;
  summary.height = output_.height;
  if (session_) {
    CloseWinRt(session_.Get());
    session_.Reset();
  }
  if (pool_) {
    CloseWinRt(pool_.Get());
    pool_.Reset();
  }
  if (audio_thread_.joinable()) {
    ::SetEvent(audio_stop_);
    audio_thread_.join();
  }
  if (audio_) {
    audio_->Stop();
  }
  summary.reason =
      ReasonName(static_cast<StopReason>(stop_reason_.load()));
  summary.encoder = writer_.hardware_encoder() ? "hardware" : "software";
  summary.audio_note = audio_note_;
  if (audio_lost_ && summary.audio_note.empty()) {
    summary.audio_note = "audio capture stopped during the recording";
  }
  if (!writer_.is_open()) {
    summary.error =
        error_.empty() ? "the video file could not be written" : error_;
    return summary;
  }
  if (frames_written_ == 0) {
    // Stopped before the first frame: one frame, so the file is valid.
    if (writer_.WriteVideo(canvas_.Get(), 0, pacer_.SampleTime(1)) == S_OK) {
      frames_written_ = 1;
      end_index_ = 1;
    }
  }
  const int64_t video_end = pacer_.SampleTime(end_index_);
  if (writer_.has_audio()) {
    const int64_t first = timeline_.frames();
    const int64_t added = timeline_.FillTo(video_end);
    if (added > 0) {
      WriteSilence(first, added);
    }
  }
  summary.audio = writer_.has_audio() && audio_live_;
  const HRESULT hr = writer_.Finalize();
  if (FAILED(hr)) {
    ::DeleteFileW(options_.path.c_str());
    summary.error = error_.empty()
                        ? HrText("finishing the video file failed", hr)
                        : error_;
    return summary;
  }
  summary.ok = true;
  summary.error = error_;
  summary.duration_ms = video_end / 10'000;
  summary.frames = frames_written_;
  summary.dropped_frames = dropped_;
  WIN32_FILE_ATTRIBUTE_DATA data = {};
  if (::GetFileAttributesExW(options_.path.c_str(), GetFileExInfoStandard,
                             &data)) {
    summary.bytes = (static_cast<int64_t>(data.nFileSizeHigh) << 32) |
                    static_cast<int64_t>(data.nFileSizeLow);
  }
  return summary;
}

void Recorder::Release() {
  if (audio_thread_.joinable()) {
    ::SetEvent(audio_stop_);
    audio_thread_.join();
  }
  if (writer_.is_open()) {
    // Set up but never finished: the file is no use.
    writer_.Abort();
    ::DeleteFileW(options_.path.c_str());
  }
  audio_.reset();
  if (session_) {
    CloseWinRt(session_.Get());
    session_.Reset();
  }
  if (pool_) {
    CloseWinRt(pool_.Get());
    pool_.Reset();
  }
  item_.Reset();
  canvas_view_.Reset();
  canvas_.Reset();
  winrt_device_.Reset();
  manager_.Reset();
  if (context_) {
    context_->ClearState();
    context_->Flush();
  }
  context_.Reset();
  device_.Reset();
}

}  // namespace

std::unique_ptr<ScreenRecorder> ScreenRecorder::Create(HWND window,
                                                       RecordOptions options,
                                                       EventCallback on_event) {
  return std::make_unique<Recorder>(window, std::move(options),
                                    std::move(on_event));
}
