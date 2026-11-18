#include "mp4_writer.h"

#include <codecapi.h>
#include <icodecapi.h>
#include <mfapi.h>
#include <mferror.h>
#include <mftransform.h>

#include <cstring>

#include "capture_util.h"

using Microsoft::WRL::ComPtr;

namespace {

// 192 kbit/s; the AAC encoder takes 12000, 16000, 20000 or 24000 bytes/s.
constexpr UINT32 kAacBytesPerSecond = 24000;

}  // namespace

Mp4Writer::Mp4Writer() = default;

Mp4Writer::~Mp4Writer() {
  Abort();
}

HRESULT Mp4Writer::Open(const Config& config, ID3D11Device* device,
                        IMFDXGIDeviceManager* manager, bool hardware) {
  Abort();
  config_ = config;
  gpu_input_ = hardware && manager != nullptr;
  audio_ = config.audio;
  hardware_encoder_ = false;
  device_ = device;
  context_.Reset();
  device_->GetImmediateContext(&context_);
  manager_ = manager;

  ComPtr<IMFAttributes> attributes;
  HRESULT hr = MFCreateAttributes(&attributes, 3);
  if (SUCCEEDED(hr)) {
    hr = attributes->SetGUID(MF_TRANSCODE_CONTAINERTYPE,
                             MFTranscodeContainerType_MPEG4);
  }
  if (SUCCEEDED(hr)) {
    hr = attributes->SetUINT32(MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS,
                               gpu_input_ ? TRUE : FALSE);
  }
  if (SUCCEEDED(hr) && gpu_input_) {
    hr = attributes->SetUnknown(MF_SINK_WRITER_D3D_MANAGER, manager);
  }
  ComPtr<IMFSinkWriter> writer;
  if (SUCCEEDED(hr)) {
    hr = MFCreateSinkWriterFromURL(config_.path.c_str(), nullptr,
                                   attributes.Get(), &writer);
  }
  if (SUCCEEDED(hr)) {
    std::lock_guard<std::mutex> lock(mutex_);
    writer_ = writer;
  }
  if (SUCCEEDED(hr)) {
    hr = AddVideoStream();
  }
  if (SUCCEEDED(hr) && audio_) {
    hr = AddAudioStream();
  }
  if (SUCCEEDED(hr)) {
    ConfigureEncoder();
    if (gpu_input_) {
      hr = MFCreateVideoSampleAllocatorEx(IID_PPV_ARGS(&allocator_));
      if (SUCCEEDED(hr)) {
        hr = allocator_->SetDirectXManager(manager_.Get());
      }
      ComPtr<IMFAttributes> textures;
      if (SUCCEEDED(hr)) {
        hr = MFCreateAttributes(&textures, 2);
      }
      if (SUCCEEDED(hr)) {
        hr = textures->SetUINT32(
            MF_SA_D3D11_BINDFLAGS,
            D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE);
      }
      if (SUCCEEDED(hr)) {
        hr = textures->SetUINT32(MF_SA_D3D11_USAGE, D3D11_USAGE_DEFAULT);
      }
      if (SUCCEEDED(hr)) {
        hr = allocator_->InitializeSampleAllocatorEx(4, 16, textures.Get(),
                                                     video_input_.Get());
      }
    } else {
      D3D11_TEXTURE2D_DESC desc = {};
      desc.Width = static_cast<UINT>(config_.width);
      desc.Height = static_cast<UINT>(config_.height);
      desc.MipLevels = 1;
      desc.ArraySize = 1;
      desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
      desc.SampleDesc.Count = 1;
      desc.Usage = D3D11_USAGE_STAGING;
      desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
      hr = device_->CreateTexture2D(&desc, nullptr, &staging_);
    }
  }
  if (SUCCEEDED(hr)) {
    hr = writer_->BeginWriting();
  }
  if (FAILED(hr)) {
    Abort();
    return hr;
  }
  DetectEncoder();
  return S_OK;
}

HRESULT Mp4Writer::AddVideoStream() {
  const UINT32 width = static_cast<UINT32>(config_.width);
  const UINT32 height = static_cast<UINT32>(config_.height);
  const UINT32 fps = static_cast<UINT32>(config_.fps);

  ComPtr<IMFMediaType> output;
  HRESULT hr = MFCreateMediaType(&output);
  if (SUCCEEDED(hr)) {
    hr = output->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
  }
  if (SUCCEEDED(hr)) {
    hr = output->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_H264);
  }
  if (SUCCEEDED(hr)) {
    hr = output->SetUINT32(
        MF_MT_AVG_BITRATE,
        capture::VideoBitrate(config_.width, config_.height, config_.fps));
  }
  if (SUCCEEDED(hr)) {
    hr = output->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
  }
  if (SUCCEEDED(hr)) {
    hr = output->SetUINT32(MF_MT_MPEG2_PROFILE, eAVEncH264VProfile_Main);
  }
  if (SUCCEEDED(hr)) {
    hr = MFSetAttributeSize(output.Get(), MF_MT_FRAME_SIZE, width, height);
  }
  if (SUCCEEDED(hr)) {
    hr = MFSetAttributeRatio(output.Get(), MF_MT_FRAME_RATE, fps, 1);
  }
  if (SUCCEEDED(hr)) {
    hr = MFSetAttributeRatio(output.Get(), MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
  }
  if (SUCCEEDED(hr)) {
    hr = writer_->AddStream(output.Get(), &video_stream_);
  }

  // GPU frames are BGRA textures (ARGB32 in Media Foundation terms; RGB32
  // would be B8G8R8X8, which a BGRA texture cannot be copied into). Frames in
  // system memory are top-down rows of the same pixels.
  ComPtr<IMFMediaType> input;
  if (SUCCEEDED(hr)) {
    hr = MFCreateMediaType(&input);
  }
  if (SUCCEEDED(hr)) {
    hr = input->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
  }
  if (SUCCEEDED(hr)) {
    hr = input->SetGUID(MF_MT_SUBTYPE, gpu_input_ ? MFVideoFormat_ARGB32
                                                  : MFVideoFormat_RGB32);
  }
  if (SUCCEEDED(hr)) {
    hr = input->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
  }
  if (SUCCEEDED(hr)) {
    hr = MFSetAttributeSize(input.Get(), MF_MT_FRAME_SIZE, width, height);
  }
  if (SUCCEEDED(hr)) {
    hr = MFSetAttributeRatio(input.Get(), MF_MT_FRAME_RATE, fps, 1);
  }
  if (SUCCEEDED(hr)) {
    hr = MFSetAttributeRatio(input.Get(), MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
  }
  if (SUCCEEDED(hr)) {
    hr = input->SetUINT32(MF_MT_DEFAULT_STRIDE, width * 4);
  }
  if (SUCCEEDED(hr)) {
    hr = input->SetUINT32(MF_MT_ALL_SAMPLES_INDEPENDENT, TRUE);
  }
  if (SUCCEEDED(hr)) {
    hr = input->SetUINT32(MF_MT_FIXED_SIZE_SAMPLES, TRUE);
  }
  if (SUCCEEDED(hr)) {
    hr = input->SetUINT32(MF_MT_SAMPLE_SIZE, width * height * 4);
  }
  if (SUCCEEDED(hr)) {
    hr = writer_->SetInputMediaType(video_stream_, input.Get(), nullptr);
  }
  if (SUCCEEDED(hr)) {
    video_input_ = input;
  }
  return hr;
}

HRESULT Mp4Writer::AddAudioStream() {
  ComPtr<IMFMediaType> output;
  HRESULT hr = MFCreateMediaType(&output);
  if (SUCCEEDED(hr)) {
    hr = output->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
  }
  if (SUCCEEDED(hr)) {
    hr = output->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_AAC);
  }
  if (SUCCEEDED(hr)) {
    hr = output->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 16);
  }
  if (SUCCEEDED(hr)) {
    hr = output->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, kAudioRate);
  }
  if (SUCCEEDED(hr)) {
    hr = output->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, kAudioChannels);
  }
  if (SUCCEEDED(hr)) {
    hr = output->SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND,
                           kAacBytesPerSecond);
  }
  if (SUCCEEDED(hr)) {
    hr = writer_->AddStream(output.Get(), &audio_stream_);
  }

  ComPtr<IMFMediaType> input;
  if (SUCCEEDED(hr)) {
    hr = MFCreateMediaType(&input);
  }
  if (SUCCEEDED(hr)) {
    hr = input->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
  }
  if (SUCCEEDED(hr)) {
    hr = input->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_PCM);
  }
  if (SUCCEEDED(hr)) {
    hr = input->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 16);
  }
  if (SUCCEEDED(hr)) {
    hr = input->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, kAudioRate);
  }
  if (SUCCEEDED(hr)) {
    hr = input->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, kAudioChannels);
  }
  if (SUCCEEDED(hr)) {
    hr = input->SetUINT32(MF_MT_AUDIO_BLOCK_ALIGNMENT, kAudioFrameBytes);
  }
  if (SUCCEEDED(hr)) {
    hr = input->SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND,
                          kAudioRate * kAudioFrameBytes);
  }
  if (SUCCEEDED(hr)) {
    hr = input->SetUINT32(MF_MT_ALL_SAMPLES_INDEPENDENT, TRUE);
  }
  if (SUCCEEDED(hr)) {
    hr = writer_->SetInputMediaType(audio_stream_, input.Get(), nullptr);
  }
  return hr;
}

void Mp4Writer::ConfigureEncoder() {
  ComPtr<ICodecAPI> codec;
  if (FAILED(writer_->GetServiceForStream(video_stream_, GUID_NULL,
                                          IID_PPV_ARGS(&codec)))) {
    return;
  }
  // A key frame every 2 seconds keeps seeking in the file quick. Encoders
  // that do not take the setting keep their own.
  VARIANT value = {};
  value.vt = VT_UI4;
  value.ulVal = static_cast<ULONG>(config_.fps) * 2;
  codec->SetValue(&CODECAPI_AVEncMPVGOPSize, &value);
}

void Mp4Writer::DetectEncoder() {
  ComPtr<IMFSinkWriterEx> writer_ex;
  if (FAILED(writer_.As(&writer_ex))) {
    return;
  }
  for (DWORD index = 0; index < 16; ++index) {
    GUID category = GUID_NULL;
    ComPtr<IMFTransform> transform;
    if (FAILED(writer_ex->GetTransformForStream(video_stream_, index,
                                                &category, &transform))) {
      return;
    }
    if (category != MFT_CATEGORY_VIDEO_ENCODER) {
      continue;
    }
    ComPtr<IMFAttributes> attributes;
    UINT32 length = 0;
    hardware_encoder_ =
        SUCCEEDED(transform->GetAttributes(&attributes)) && attributes &&
        SUCCEEDED(attributes->GetStringLength(MFT_ENUM_HARDWARE_URL_Attribute,
                                              &length));
    return;
  }
}

HRESULT Mp4Writer::CreateGpuSample(ID3D11Texture2D* frame,
                                   IMFSample** result) {
  ComPtr<IMFSample> sample;
  HRESULT hr = allocator_->AllocateSample(&sample);
  if (hr == MF_E_SAMPLEALLOCATOR_EMPTY) {
    return S_FALSE;
  }
  ComPtr<IMFMediaBuffer> buffer;
  if (SUCCEEDED(hr)) {
    hr = sample->GetBufferByIndex(0, &buffer);
  }
  ComPtr<IMFDXGIBuffer> dxgi_buffer;
  if (SUCCEEDED(hr)) {
    hr = buffer.As(&dxgi_buffer);
  }
  ComPtr<ID3D11Texture2D> texture;
  if (SUCCEEDED(hr)) {
    hr = dxgi_buffer->GetResource(IID_PPV_ARGS(&texture));
  }
  UINT subresource = 0;
  if (SUCCEEDED(hr)) {
    hr = dxgi_buffer->GetSubresourceIndex(&subresource);
  }
  if (FAILED(hr)) {
    return hr;
  }
  context_->CopySubresourceRegion(texture.Get(), subresource, 0, 0, 0, frame,
                                  0, nullptr);
  ComPtr<IMF2DBuffer> buffer_2d;
  DWORD length = 0;
  if (SUCCEEDED(buffer.As(&buffer_2d)) &&
      SUCCEEDED(buffer_2d->GetContiguousLength(&length))) {
    buffer->SetCurrentLength(length);
  }
  *result = sample.Detach();
  return S_OK;
}

HRESULT Mp4Writer::CreateMemorySample(ID3D11Texture2D* frame,
                                      IMFSample** result) {
  const DWORD stride = static_cast<DWORD>(config_.width) * 4;
  const DWORD size = stride * static_cast<DWORD>(config_.height);
  ComPtr<IMFMediaBuffer> buffer;
  HRESULT hr = MFCreateMemoryBuffer(size, &buffer);
  if (FAILED(hr)) {
    return hr;
  }
  context_->CopyResource(staging_.Get(), frame);
  D3D11_MAPPED_SUBRESOURCE mapped = {};
  hr = context_->Map(staging_.Get(), 0, D3D11_MAP_READ, 0, &mapped);
  if (FAILED(hr)) {
    return hr;
  }
  BYTE* destination = nullptr;
  hr = buffer->Lock(&destination, nullptr, nullptr);
  if (SUCCEEDED(hr)) {
    hr = MFCopyImage(destination, static_cast<LONG>(stride),
                     static_cast<const BYTE*>(mapped.pData),
                     static_cast<LONG>(mapped.RowPitch), stride,
                     static_cast<DWORD>(config_.height));
    buffer->Unlock();
  }
  context_->Unmap(staging_.Get(), 0);
  if (SUCCEEDED(hr)) {
    hr = buffer->SetCurrentLength(size);
  }
  ComPtr<IMFSample> sample;
  if (SUCCEEDED(hr)) {
    hr = MFCreateSample(&sample);
  }
  if (SUCCEEDED(hr)) {
    hr = sample->AddBuffer(buffer.Get());
  }
  if (SUCCEEDED(hr)) {
    *result = sample.Detach();
  }
  return hr;
}

HRESULT Mp4Writer::WriteVideo(ID3D11Texture2D* frame, int64_t time,
                              int64_t duration) {
  if (!writer_) {
    return E_UNEXPECTED;
  }
  ComPtr<IMFSample> sample;
  const HRESULT made = gpu_input_ ? CreateGpuSample(frame, &sample)
                                  : CreateMemorySample(frame, &sample);
  if (made != S_OK) {
    return made;
  }
  HRESULT hr = sample->SetSampleTime(time);
  if (SUCCEEDED(hr)) {
    hr = sample->SetSampleDuration(duration);
  }
  if (FAILED(hr)) {
    return hr;
  }
  std::lock_guard<std::mutex> lock(mutex_);
  if (!writer_) {
    return E_UNEXPECTED;
  }
  return writer_->WriteSample(video_stream_, sample.Get());
}

HRESULT Mp4Writer::WriteAudio(const BYTE* data, uint32_t frames, int64_t time,
                              int64_t duration) {
  if (!audio_ || frames == 0) {
    return E_UNEXPECTED;
  }
  const DWORD size = frames * kAudioFrameBytes;
  ComPtr<IMFMediaBuffer> buffer;
  HRESULT hr = MFCreateMemoryBuffer(size, &buffer);
  BYTE* destination = nullptr;
  if (SUCCEEDED(hr)) {
    hr = buffer->Lock(&destination, nullptr, nullptr);
  }
  if (SUCCEEDED(hr)) {
    if (data != nullptr) {
      std::memcpy(destination, data, size);
    } else {
      std::memset(destination, 0, size);
    }
    buffer->Unlock();
    hr = buffer->SetCurrentLength(size);
  }
  ComPtr<IMFSample> sample;
  if (SUCCEEDED(hr)) {
    hr = MFCreateSample(&sample);
  }
  if (SUCCEEDED(hr)) {
    hr = sample->AddBuffer(buffer.Get());
  }
  if (SUCCEEDED(hr)) {
    hr = sample->SetSampleTime(time);
  }
  if (SUCCEEDED(hr)) {
    hr = sample->SetSampleDuration(duration);
  }
  if (FAILED(hr)) {
    return hr;
  }
  std::lock_guard<std::mutex> lock(mutex_);
  if (!writer_) {
    return E_UNEXPECTED;
  }
  return writer_->WriteSample(audio_stream_, sample.Get());
}

HRESULT Mp4Writer::Finalize() {
  HRESULT hr = E_UNEXPECTED;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (writer_) {
      hr = writer_->Finalize();
    }
  }
  Abort();
  return hr;
}

void Mp4Writer::Abort() {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    writer_.Reset();
  }
  if (allocator_) {
    allocator_->UninitializeSampleAllocator();
    allocator_.Reset();
  }
  staging_.Reset();
  video_input_.Reset();
  manager_.Reset();
  context_.Reset();
  device_.Reset();
}
