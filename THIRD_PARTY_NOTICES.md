# 第三方组件

simple_live_N 依照 GPL-3.0 发布，许可全文见 [`LICENSE`](LICENSE)。与各个 Release 对应的源码即本仓库中同一版本号的提交。

安装包中还包含以下第三方组件，它们分别遵循各自的许可。

## Windows 安装包

| 组件 | 文件 | 许可 | 来源 |
|---|---|---|---|
| Flutter 引擎 | `flutter_windows.dll`、`data\icudtl.dat` | BSD-3-Clause | [flutter/flutter](https://github.com/flutter/flutter) |
| libmpv（含 FFmpeg） | `libmpv-2.dll` | mpv 与 FFmpeg 的 LGPL-2.1 或更高版本 / GPL-2.0 或更高版本，取决于构建配置 | 构建来自 [Predidit/libmpv-win32-video-cmake](https://github.com/Predidit/libmpv-win32-video-cmake) 的发布 `202611120335`，构建脚本和上游源码见该仓库；上游为 [mpv-player/mpv](https://github.com/mpv-player/mpv)、[FFmpeg](https://ffmpeg.org/) |
| QuickJS | `dart_quickjs.dll` | MIT | [xiaoyaocz/dart_quickjs](https://github.com/xiaoyaocz/dart_quickjs) |
| WebView2 加载器 | `WebView2Loader.dll` | Microsoft WebView2 SDK 许可（允许随应用再分发） | [Microsoft.Web.WebView2](https://www.nuget.org/packages/Microsoft.Web.WebView2) |
| 各插件的原生部分 | `*_plugin.dll` 等 | 见各插件的许可 | 依赖见 `simple_live_app/pubspec.yaml` |

## Windows 7 安装包

除上表外（libmpv 换为下表中的版本），另包含：

| 组件 | 文件 | 许可 | 来源 |
|---|---|---|---|
| libmpv（含 FFmpeg） | `libmpv-2.dll` | 同上，取决于构建配置 | [media-kit/libmpv-win32-video-build](https://github.com/media-kit/libmpv-win32-video-build) 的发布 `2023-09-24`（由 media_kit_libs_windows_video 1.0.11 下载） |
| ANGLE | `libEGL.dll`、`libGLESv2.dll` | BSD-3-Clause | [alexmercerind/flutter-windows-ANGLE-OpenGL-ES](https://github.com/alexmercerind/flutter-windows-ANGLE-OpenGL-ES) 的发布 `v1.0.1`，上游为 [google/angle](https://chromium.googlesource.com/angle/angle) |
| SwiftShader、Vulkan 加载器 | `vk_swiftshader.dll`、`vulkan-1.dll` | Apache-2.0 | 随上述 ANGLE 发布提供 |
| zlib | `zlib.dll` | zlib 许可 | 随上述 ANGLE 发布提供 |
| D3D 着色器编译器 | `d3dcompiler_47.dll` | Microsoft 可再发行组件 | 随上述 ANGLE 发布提供 |
| Windows 7 替代 DLL | `k32w7.dll`、`ws2w7.dll`、`ntdw7.dll`、`api-ms-win-core-*.dll` | GPL-3.0（本项目） | 本仓库的 [`windows7/`](windows7) |

## 源码中的第三方代码

| 目录 | 内容 | 许可 |
|---|---|---|
| `simple_live_app/third_party/media_kit_video`、`windows7/media_kit_video_windows` | media_kit_video（含本项目的修改） | MIT，见该目录的 `LICENSE` |
| `simple_live_app/third_party/media_kit_libs_windows_video` | media_kit_libs_windows_video（含本项目的修改） | MIT，见该目录的 `LICENSE` |
| `simple_live_app/third_party/canvas_danmaku` | canvas_danmaku（含本项目的修改） | MIT，见该目录的 `LICENSE` |

Dart 依赖包的许可见各包自身，依赖列表见 `simple_live_app/pubspec.yaml` 和 `simple_live_core/pubspec.yaml`。
