// This file is a part of media_kit
// (https://github.com/media-kit/media-kit).
//
// Copyright © 2026 Predidit.
// All rights reserved.
// Use of this source code is governed by MIT license that can be found in the
// LICENSE file.

#include "d3d11_renderer.h"

#include <d3d11_4.h>

#include <iostream>

#pragma comment(lib, "dxgi.lib")
#pragma comment(lib, "d3d11.lib")

int D3D11Renderer::instance_count_ = 0;

D3D11Renderer::D3D11Renderer(int32_t width, int32_t height,
                             IDXGIAdapter* flutter_adapter)
    : width_(width), height_(height) {
  if (!CreateD3D11Device(flutter_adapter)) {
    throw std::runtime_error("Unable to create Direct3D 11 device.");
  }
  if (!CreateTexture()) {
    throw std::runtime_error("Unable to create the shared render target.");
  }
  instance_count_++;
}

D3D11Renderer::~D3D11Renderer() {
  shared_handle_.store(nullptr, std::memory_order_release);
  {
    std::lock_guard<std::mutex> lock(retired_mutex_);
    retired_.clear();
  }
  texture_.Reset();
  d3d_11_device_context_.Reset();
  d3d_11_device_.Reset();
  instance_count_--;
}

void D3D11Renderer::SetSize(int32_t width, int32_t height,
                            int64_t retire_tag) {
  if (width == width_ && height == height_) return;
  width_ = width;
  height_ = height;
  if (!CreateTexture(retire_tag)) {
    std::cout << "media_kit: D3D11Renderer: Resize failed." << std::endl;
  }
}

void D3D11Renderer::ReleaseRetired(int64_t tag) {
  std::lock_guard<std::mutex> lock(retired_mutex_);
  for (auto it = retired_.begin(); it != retired_.end();) {
    if (it->first == tag) {
      it = retired_.erase(it);
    } else {
      ++it;
    }
  }
}

void D3D11Renderer::ProducerCommit() {
  if (d3d_11_device_context_) {
    d3d_11_device_context_->Flush();
  }
}

bool D3D11Renderer::CreateD3D11Device(IDXGIAdapter* flutter_adapter) {
  if (d3d_11_device_) return true;

  const D3D_FEATURE_LEVEL feature_levels[] = {
      D3D_FEATURE_LEVEL_11_1,
      D3D_FEATURE_LEVEL_11_0,
      D3D_FEATURE_LEVEL_10_1,
      D3D_FEATURE_LEVEL_10_0,
      D3D_FEATURE_LEVEL_9_3,
  };

  Microsoft::WRL::ComPtr<IDXGIAdapter> adapter(flutter_adapter);
  D3D_DRIVER_TYPE driver_type = D3D_DRIVER_TYPE_UNKNOWN;

  if (!adapter) {
    if (Utils::IsWindows10RTMOrGreater()) {
      driver_type = D3D_DRIVER_TYPE_HARDWARE;
    } else {
      Microsoft::WRL::ComPtr<IDXGIFactory> dxgi;
      ::CreateDXGIFactory(__uuidof(IDXGIFactory), (void**)&dxgi);
      if (dxgi) {
        dxgi->EnumAdapters(0, &adapter);
      }
    }
  } else {
    std::cout << "media_kit: D3D11Renderer: Using Flutter's DXGI adapter."
              << std::endl;
  }

  // No driver-internal worker threads for this device: all our D3D11 calls
  // already come from mpv's threads. (Earlier crashes in nvwgf2umx.dll came
  // from Flutter's Skia renderer, not from this device; see
  // windows/runner/main.cpp.)
  const HRESULT hr = ::D3D11CreateDevice(
      adapter.Get(), driver_type, nullptr,
      D3D11_CREATE_DEVICE_BGRA_SUPPORT |
          D3D11_CREATE_DEVICE_PREVENT_INTERNAL_THREADING_OPTIMIZATIONS,
      feature_levels, static_cast<UINT>(std::size(feature_levels)),
      D3D11_SDK_VERSION, d3d_11_device_.GetAddressOf(), nullptr,
      d3d_11_device_context_.GetAddressOf());

  if (FAILED(hr)) {
    std::cout << "media_kit: D3D11Renderer: D3D11CreateDevice failed (hr=0x"
              << std::hex << hr << std::dec << ")" << std::endl;
    return false;
  }

  // mpv's decoder (d3d11va) and renderer use this device from different
  // threads; serialize the immediate context.
  Microsoft::WRL::ComPtr<ID3D11Multithread> multithread;
  if (SUCCEEDED(d3d_11_device_context_.As(&multithread)) && multithread) {
    multithread->SetMultithreadProtected(TRUE);
  }

  Microsoft::WRL::ComPtr<IDXGIDevice> dxgi_device;
  if (SUCCEEDED(d3d_11_device_->QueryInterface(__uuidof(IDXGIDevice),
                                               (void**)&dxgi_device)) &&
      dxgi_device) {
    dxgi_device->SetGPUThreadPriority(5);
  }

  const auto level = d3d_11_device_->GetFeatureLevel();
  std::cout << "media_kit: D3D11Renderer: Direct3D Feature Level: "
            << (static_cast<unsigned>(level) >> 12) << "_"
            << ((static_cast<unsigned>(level) >> 8) & 0xfu) << std::endl;

  return true;
}

bool D3D11Renderer::CreateTexture(int64_t retire_tag) {
  D3D11_TEXTURE2D_DESC desc = {};
  desc.Width = static_cast<UINT>(width_ > 0 ? width_ : 1);
  desc.Height = static_cast<UINT>(height_ > 0 ? height_ : 1);
  desc.MipLevels = 1;
  desc.ArraySize = 1;
  desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
  desc.SampleDesc.Count = 1;
  desc.Usage = D3D11_USAGE_DEFAULT;
  desc.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
  desc.MiscFlags = D3D11_RESOURCE_MISC_SHARED;

  Microsoft::WRL::ComPtr<ID3D11Texture2D> texture;
  HRESULT hr = d3d_11_device_->CreateTexture2D(&desc, nullptr, &texture);
  if (FAILED(hr)) {
    std::cout << "media_kit: D3D11Renderer: CreateTexture2D failed (hr=0x"
              << std::hex << hr << std::dec << ")" << std::endl;
    return false;
  }
  Microsoft::WRL::ComPtr<IDXGIResource> resource;
  HANDLE handle = nullptr;
  hr = texture.As(&resource);
  if (SUCCEEDED(hr)) {
    hr = resource->GetSharedHandle(&handle);
  }
  if (FAILED(hr) || handle == nullptr) {
    std::cout << "media_kit: D3D11Renderer: GetSharedHandle failed (hr=0x"
              << std::hex << hr << std::dec << ")" << std::endl;
    return false;
  }
  // tag 0: Flutter never saw this texture, free it now
  if (texture_ && retire_tag != 0) {
    std::lock_guard<std::mutex> lock(retired_mutex_);
    retired_.emplace_back(retire_tag, texture_);
    // never let a missed release pile up textures
    while (retired_.size() > 8) {
      retired_.erase(retired_.begin());
    }
  }
  texture_ = texture;
  shared_handle_.store(handle, std::memory_order_release);
  return true;
}
