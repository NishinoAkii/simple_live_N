// This file is a part of media_kit
// (https://github.com/media-kit/media-kit).
//
// Copyright © 2026 Predidit.
// All rights reserved.
// Use of this source code is governed by MIT license that can be found in the
// LICENSE file.
//
// SimpleLive: one shared render target per size instead of the fork's 4-slot
// mailbox (see SIMPLE_LIVE_PATCHES.md).

#ifndef D3D11_RENDERER_H_
#define D3D11_RENDERER_H_

#include <Windows.h>
#include <d3d11.h>
#include <dxgi.h>
#include <dxgi1_2.h>
#include <wrl.h>

#include <atomic>
#include <cstdint>
#include <iostream>
#include <memory>
#include <mutex>
#include <utility>
#include <vector>

#include "utils.h"

// Owns the Direct3D 11 device mpv renders with, and the texture it renders
// into. Flutter reads the same texture through its DXGI shared handle.
//
// The handle only changes when the size changes. Flutter's engine reopens the
// shared texture whenever the handle it is given changes; doing that every
// frame (as a rotating swap chain would) makes the process's GPU memory
// accounting grow without bound.
class D3D11Renderer {
 public:
  int32_t width() const { return width_; }
  int32_t height() const { return height_; }

  ID3D11Device* device() const { return d3d_11_device_.Get(); }

  // Texture for MPV_RENDER_PARAM_D3D11_FBO.
  ID3D11Texture2D* render_target() const { return texture_.Get(); }

  explicit D3D11Renderer(int32_t width, int32_t height,
                         IDXGIAdapter* flutter_adapter = nullptr);
  ~D3D11Renderer();

  // Recreates the texture (and so its shared handle) when the size changes.
  // The old texture is kept alive, tagged with [retire_tag] (the Flutter texture
  // id that showed it), until ReleaseRetired(retire_tag): Flutter's compositor
  // can still be reading its shared handle until that id is unregistered;
  // freeing it earlier would let Flutter read a released resource (compare
  // media-kit PR #1468).
  void SetSize(int32_t width, int32_t height, int64_t retire_tag = 0);

  // Frees the textures replaced while [tag] was the registered texture id.
  // Safe from any thread.
  void ReleaseRetired(int64_t tag);

  // Called after mpv rendered a frame: submits the work to the GPU now, so
  // Flutter's device sees the finished frame.
  void ProducerCommit();

  // Shared handle of the texture, for Flutter. Safe from any thread.
  HANDLE ConsumerAcquire() const {
    return shared_handle_.load(std::memory_order_acquire);
  }
  HANDLE ReadHandleSnapshot() const { return ConsumerAcquire(); }

 private:
  bool CreateD3D11Device(IDXGIAdapter* flutter_adapter);
  bool CreateTexture(int64_t retire_tag = 0);

  int32_t width_ = 1;
  int32_t height_ = 1;

  Microsoft::WRL::ComPtr<ID3D11Device> d3d_11_device_;
  Microsoft::WRL::ComPtr<ID3D11DeviceContext> d3d_11_device_context_;
  Microsoft::WRL::ComPtr<ID3D11Texture2D> texture_;
  std::atomic<HANDLE> shared_handle_{nullptr};

  std::mutex retired_mutex_;
  std::vector<std::pair<int64_t, Microsoft::WRL::ComPtr<ID3D11Texture2D>>>
      retired_;

  static int instance_count_;
};

#endif  // D3D11_RENDERER_H_
