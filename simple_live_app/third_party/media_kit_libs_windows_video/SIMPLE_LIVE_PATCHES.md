# media_kit_libs_windows_video 1.0.11 — SimpleLive patches

Copied from pub.dev `media_kit_libs_windows_video` 1.0.11 (MIT, see LICENSE).
Only `windows/CMakeLists.txt` is changed:

- libmpv is `mpv-dev-x86_64-20261112-git-bcde6b9.7z` from
  Predidit/libmpv-win32-video-cmake (mpv bcde6b9, 2026-11-12, the build Kazumi
  2.4.4 ships). It has mpv's D3D11 render API (`render_d3d11.h`), which
  `third_party/media_kit_video` now renders through. Checked by SHA-256.
- It is extracted while configuring, into a folder named after the build, and
  `MEDIA_KIT_LIBMPV_DIR` tells media_kit_video where it is.
- ANGLE is no longer downloaded or bundled.
