# media_kit_video 2.0.1 — SimpleLive patches

Copied from pub.dev `media_kit_video` 2.0.1 (MIT, see LICENSE). Only the iOS
sources under `ios/Classes/plugin/` are changed, to support iOS
picture-in-picture by switching a player's output between GPU and CPU
rendering without recreating the mpv player. The design follows
Predidit/media-kit PR #41 (adapted to 2.0.1):

- `MediaKitVideoPlugin`: publishes itself (`registrar.publish`) and exposes
  `setSoftwareRendering(handle:enabled:completion:)`,
  `setSoftwareRenderingForNewOutputs(_:)`, `softwareRenderingHandles`,
  `setRenderSizeLimit(_:)` (caps the rendered size, aspect ratio kept; picture
  in picture renders at most 960x540) and
  `setBackgroundSoftwareRenderingAllowed(_:)` (software outputs stop rendering
  in the background unless picture in picture shows them).
- `VideoOutputManager`: keeps per-player configuration, swaps outputs only
  after the previous render context is freed, rolls back on failure.
- `VideoOutput`: `dispose(completion:)`, initialization completion, and a
  render gate that stops OpenGL ES rendering while the app is inactive.
- `TextureSW` / `TextureHW`: synchronous, failable initialization and
  `invalidate()` to free the mpv render context immediately.
- `OpenGLESHelpers`: non-crashing `tryCreateContext` / `tryCreateTextureCache`.

Windows (`windows/`): video is rendered through mpv's D3D11 render API into a
shared D3D11 texture that Flutter reads through its DXGI shared handle, so
hardware-decoded frames stay on the GPU (`hwdec=auto` picks `d3d11va`, not
`d3d11va-copy`). `d3d11_renderer.*`, `video_output.*`, `video_output_manager.*`
and `video_dimensions.h` come from Predidit/media-kit f8ae9aac (MIT);
`VideoOutputManager.Dispose` now answers after the render context is freed.
The fork's 4-slot mailbox is replaced by one texture per size: Flutter's
engine reopens the shared texture whenever the handle changes, and with a
handle per frame the process's GPU dedicated usage grew by about one frame
(8 MB at 1080p) per frame without coming back down (measured 52 GB "used"
after 75 s). With a stable handle it stays flat, as with the old ANGLE path. Unlike the fork, the plugin links libmpv directly (no runtime
symbol binding), so the Dart side is unchanged. ANGLE is gone; software
rendering is still the fallback. Needs the libmpv from
`third_party/media_kit_libs_windows_video`.

Other platforms are unchanged from 2.0.1.
