#include "audio_loopback.h"

#include <audioclientactivationparams.h>
#include <mmdeviceapi.h>
#include <objidl.h>

#include <cstdio>

#include "mp4_writer.h"

using Microsoft::WRL::ComPtr;

namespace {

// How long the activation may take before the recording goes on without
// audio.
constexpr DWORD kActivateTimeoutMs = 3000;
// The capture buffer: room for the recorder's audio thread to be late.
constexpr REFERENCE_TIME kBufferDuration = 5'000'000;  // 500 ms

std::string Reason(const char* what, HRESULT hr) {
  char text[96];
  std::snprintf(text, sizeof(text), "%s (0x%08lX)", what,
                static_cast<unsigned long>(hr));
  return text;
}

// The completion handler ActivateAudioInterfaceAsync calls on one of its own
// threads; it has to be agile.
class ActivationHandler final : public IActivateAudioInterfaceCompletionHandler,
                                public IAgileObject {
 public:
  ActivationHandler()
      : done_(::CreateEventW(nullptr, TRUE, FALSE, nullptr)) {}

  HANDLE done() const { return done_; }

  // IUnknown
  STDMETHODIMP QueryInterface(REFIID iid, void** object) override {
    if (object == nullptr) {
      return E_POINTER;
    }
    if (iid == __uuidof(IUnknown) ||
        iid == __uuidof(IActivateAudioInterfaceCompletionHandler)) {
      *object = static_cast<IActivateAudioInterfaceCompletionHandler*>(this);
    } else if (iid == __uuidof(IAgileObject)) {
      *object = static_cast<IAgileObject*>(this);
    } else {
      *object = nullptr;
      return E_NOINTERFACE;
    }
    AddRef();
    return S_OK;
  }
  STDMETHODIMP_(ULONG) AddRef() override {
    return static_cast<ULONG>(::InterlockedIncrement(&references_));
  }
  STDMETHODIMP_(ULONG) Release() override {
    const LONG left = ::InterlockedDecrement(&references_);
    if (left == 0) {
      delete this;
    }
    return static_cast<ULONG>(left);
  }

  // IActivateAudioInterfaceCompletionHandler
  STDMETHODIMP ActivateCompleted(
      IActivateAudioInterfaceAsyncOperation* operation) override {
    ::SetEvent(done_);
    return S_OK;
  }

 private:
  ~ActivationHandler() {
    if (done_ != nullptr) {
      ::CloseHandle(done_);
    }
  }

  LONG references_ = 1;
  HANDLE done_;
};

}  // namespace

AudioLoopback::AudioLoopback() = default;

AudioLoopback::~AudioLoopback() {
  Stop();
  capture_.Reset();
  client_.Reset();
  if (event_ != nullptr) {
    ::CloseHandle(event_);
  }
}

std::string AudioLoopback::Open() {
  AUDIOCLIENT_ACTIVATION_PARAMS parameters = {};
  parameters.ActivationType = AUDIOCLIENT_ACTIVATION_TYPE_PROCESS_LOOPBACK;
  parameters.ProcessLoopbackParams.TargetProcessId = ::GetCurrentProcessId();
  parameters.ProcessLoopbackParams.ProcessLoopbackMode =
      PROCESS_LOOPBACK_MODE_INCLUDE_TARGET_PROCESS_TREE;
  PROPVARIANT activation = {};
  activation.vt = VT_BLOB;
  activation.blob.cbSize = sizeof(parameters);
  activation.blob.pBlobData = reinterpret_cast<BYTE*>(&parameters);

  ComPtr<ActivationHandler> handler;
  handler.Attach(new ActivationHandler());
  if (handler->done() == nullptr) {
    return "audio capture: no event";
  }
  ComPtr<IActivateAudioInterfaceAsyncOperation> operation;
  HRESULT hr = ::ActivateAudioInterfaceAsync(
      VIRTUAL_AUDIO_DEVICE_PROCESS_LOOPBACK, __uuidof(IAudioClient),
      &activation, handler.Get(), &operation);
  if (FAILED(hr)) {
    return Reason("audio capture unavailable", hr);
  }
  if (::WaitForSingleObject(handler->done(), kActivateTimeoutMs) !=
      WAIT_OBJECT_0) {
    return "audio capture did not start in time";
  }
  HRESULT activate_result = E_FAIL;
  ComPtr<IUnknown> activated;
  hr = operation->GetActivateResult(&activate_result, &activated);
  if (SUCCEEDED(hr)) {
    hr = activate_result;
  }
  if (SUCCEEDED(hr)) {
    hr = activated.As(&client_);
  }
  if (FAILED(hr)) {
    return Reason("audio capture unavailable", hr);
  }

  WAVEFORMATEX format = {};
  format.wFormatTag = WAVE_FORMAT_PCM;
  format.nChannels = Mp4Writer::kAudioChannels;
  format.nSamplesPerSec = Mp4Writer::kAudioRate;
  format.wBitsPerSample = 16;
  format.nBlockAlign = Mp4Writer::kAudioFrameBytes;
  format.nAvgBytesPerSec = Mp4Writer::kAudioRate * Mp4Writer::kAudioFrameBytes;
  const DWORD flags =
      AUDCLNT_STREAMFLAGS_LOOPBACK | AUDCLNT_STREAMFLAGS_EVENTCALLBACK;
  // The loopback client converts to the format asked for; the explicit
  // conversion flags are a fallback for builds that want them.
  hr = client_->Initialize(AUDCLNT_SHAREMODE_SHARED, flags, kBufferDuration, 0,
                           &format, nullptr);
  if (FAILED(hr)) {
    hr = client_->Initialize(AUDCLNT_SHAREMODE_SHARED,
                             flags | AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM |
                                 AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY,
                             kBufferDuration, 0, &format, nullptr);
  }
  if (FAILED(hr)) {
    client_.Reset();
    return Reason("audio capture format refused", hr);
  }
  event_ = ::CreateEventW(nullptr, FALSE, FALSE, nullptr);
  if (event_ == nullptr) {
    client_.Reset();
    return "audio capture: no event";
  }
  hr = client_->SetEventHandle(event_);
  if (SUCCEEDED(hr)) {
    hr = client_->GetService(IID_PPV_ARGS(&capture_));
  }
  if (FAILED(hr)) {
    capture_.Reset();
    client_.Reset();
    return Reason("audio capture setup failed", hr);
  }
  return std::string();
}

HRESULT AudioLoopback::Start() {
  if (!client_) {
    return E_UNEXPECTED;
  }
  const HRESULT hr = client_->Start();
  started_ = SUCCEEDED(hr);
  return hr;
}

HRESULT AudioLoopback::Stop() {
  if (!client_ || !started_) {
    return S_FALSE;
  }
  started_ = false;
  return client_->Stop();
}

HRESULT AudioLoopback::Drain(const PacketSink& sink) {
  if (!capture_) {
    return E_UNEXPECTED;
  }
  for (int packets = 0; packets < 1000; ++packets) {
    UINT32 next = 0;
    HRESULT hr = capture_->GetNextPacketSize(&next);
    if (FAILED(hr) || next == 0) {
      return hr;
    }
    BYTE* data = nullptr;
    UINT32 frames = 0;
    DWORD flags = 0;
    UINT64 position = 0;
    UINT64 time = 0;
    hr = capture_->GetBuffer(&data, &frames, &flags, &position, &time);
    if (FAILED(hr)) {
      return hr;
    }
    if (hr == AUDCLNT_S_BUFFER_EMPTY) {
      return S_OK;
    }
    if (frames > 0) {
      const bool silent = (flags & AUDCLNT_BUFFERFLAGS_SILENT) != 0;
      const bool timed = (flags & AUDCLNT_BUFFERFLAGS_TIMESTAMP_ERROR) == 0;
      sink(silent ? nullptr : data, frames,
           timed ? static_cast<int64_t>(time) : 0);
    }
    hr = capture_->ReleaseBuffer(frames);
    if (FAILED(hr)) {
      return hr;
    }
  }
  return S_OK;
}
