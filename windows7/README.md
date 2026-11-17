# Windows 7 安装包

本目录用于编译 simple_live_N 的 Windows 7 安装包，包含编译脚本、视频播放的旧版代码和兼容 DLL 的源码。Windows 7 安装包保持 1.24.0 的功能：发现问题会修复并重新编译，但不再加入新功能。

编译有两种方式，结果相同：在本地运行下文的脚本，或者在 GitHub 的 Actions 页面手动运行“Windows 7 package”工作流（[`.github/workflows/build_win7.yml`](../.github/workflows/build_win7.yml)）。工作流不会自动运行，可以把安装包直接附加到指定的 Release。

## 与 Windows 10/11 安装包的区别

| 项目 | Windows 7 安装包 |
|---|---|
| 视频播放 | Direct3D 11 渲染和新版 libmpv 需要 Windows 8 及以上，因此改用 media_kit_video 的旧版 Windows 代码（[`media_kit_video_windows/`](media_kit_video_windows)）和旧版 libmpv。CPU 占用较高。 |
| 系统通知 | 不支持。开播提醒依赖 Windows 8 及以上的系统通知。 |
| 系统分享 | 不支持。分享时改为复制链接，文件则在资源管理器中选中。 |
| 其他功能 | 与 Windows 10/11 安装包相同。 |

Flutter 引擎和部分插件调用了 Windows 8 及以上才有的系统函数。安装包附带的兼容 DLL（`k32w7.dll`、`ws2w7.dll`、`ntdw7.dll` 和几个 `api-ms-win-core-*.dll`）在 Windows 8 及以上直接调用系统函数，在 Windows 7 上改用替代实现或返回错误，使程序能够启动。

本安装包尚未在 Windows 7 实机上测试。

## 运行要求

- Windows 7 SP1（64 位）。
- [Microsoft Visual C++ Redistributable (x64)](https://aka.ms/vs/17/release/vc_redist.x64.exe)。
- 网页登录需要 Microsoft Edge WebView2 Runtime，Windows 7 可用的最后版本为 109。

## 编译

在 Windows 10 或 11 上编译，需要：

- Flutter 3.50.0（在 PATH 中）。
- Visual Studio 2022 或更高版本，安装 Desktop development with C++ 工作负载，并勾选 C++ ATL。
- Python 3（在 PATH 中，或用 `-Python` 指定）。
- Git。

在仓库根目录运行：

```powershell
powershell -ExecutionPolicy Bypass -File windows7\build_win7.ps1
```

脚本依次完成以下步骤：

1. 用旧版视频代码替换 `simple_live_app/third_party/media_kit_video/windows`，并改用 pub.dev 上的 media_kit_libs_windows_video。
2. 编译 Release 版本。
3. 生成并编译兼容 DLL（[`shims/`](shims)），修改 `flutter_windows.dll` 和通知插件的导入表，使其通过兼容 DLL 调用系统函数。
4. 检查兼容 DLL 是否覆盖全部导入，以及安装包中是否还有需要 Windows 8 及以上的依赖。
5. 放入 `LICENSE.txt` 和 `THIRD_PARTY_NOTICES.md`，打包为 `simple_live_app/build/win7/` 下的 zip 文件。

编译结束后，脚本用 Git 把 `simple_live_app` 恢复原状，因此 `simple_live_app` 中有未提交的修改时脚本不会运行。

## 许可

- `media_kit_video_windows/`：media_kit_video 的 Windows 代码（含本项目的修改），MIT 许可，见该目录的 `LICENSE`。
- `shims/` 和 `build_win7.ps1`：本项目的一部分，依照 GPL-3.0 发布。
- 安装包中的第三方组件见 [`THIRD_PARTY_NOTICES.md`](../THIRD_PARTY_NOTICES.md)。
