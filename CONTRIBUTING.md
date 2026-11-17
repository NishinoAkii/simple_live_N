简体中文 | [English](CONTRIBUTING.en.md)

# 参与贡献

欢迎提交问题、建议和代码。

## 提交问题

| 内容 | 去处 |
|---|---|
| App 出错、闪退或功能不正常 | [Issue](https://github.com/NishinoAkii/simple_live_N/issues/new/choose)，选“Bug 报告” |
| 新功能或改进 | [Issue](https://github.com/NishinoAkii/simple_live_N/issues/new/choose)，选“功能建议” |
| 使用方法、设置等问题 | [Discussions](https://github.com/NishinoAkii/simple_live_N/discussions) |
| 直播源脚本、新直播源、翻译 | [simple_live_N-sources](https://github.com/NishinoAkii/simple_live_N-sources/issues) |

常见问题和基础的排查方法见置顶的[必读 Issue](https://github.com/NishinoAkii/simple_live_N/issues/2)。报告 Bug 时请写明版本、系统、直播平台和直播间，并附上重现步骤和日志：在“我的 → 其他设置”中开启“调试模式”，重现问题后点“导出日志”。导出的日志会隐藏账号和 Cookie，上传前仍请检查一遍。不要在 Issue 中贴出账号、Cookie 或密码。

## 提交代码

### 环境

- Flutter 3.50.0（与 `simple_live_app/.fvmrc` 一致）。
- `simple_live_core` 是核心库（各平台的接口、弹幕和直播源），`simple_live_app` 是 App，`simple_live_tv_app` 是 Android TV 版。

```sh
cd simple_live_app
flutter pub get
flutter run
```

### 提交前

1. `dart analyze` 没有新增问题。只格式化修改过的文件（`dart format <文件>`），不要格式化整个目录。
2. 运行相关的单元测试：

   ```sh
   cd simple_live_core && dart test test/<文件>
   cd simple_live_app && flutter test test/<文件>
   ```

   CI 运行的测试列表见 [`.github/workflows/build.yml`](.github/workflows/build.yml)。核心库中访问真实网站的测试带有 `live` 标签，默认跳过。新功能请附带不访问网络的测试。
3. 新增的界面文字以简体中文作为键，并在 `simple_live_app/assets/lang/` 的 `zh-Hant.json` 和 `en.json` 中加入译文，见 [`doc/translation.md`](doc/translation.md)。
4. 不要提交账号、Cookie、密钥或本机路径。

### Pull Request

1. Fork 本仓库，从 `main` 新建分支。
2. 一个 PR 只做一件事，按模板写明改动内容和测试情况。
3. 合并后的改动会在下一个版本发布，版本号和 [`CHANGELOG.md`](CHANGELOG.md) 由维护者更新。

## 接入新平台

优先写成直播源脚本：脚本更新不需要等 App 发布，编写方法见 [GUIDE](https://github.com/NishinoAkii/simple_live_N-sources/blob/main/GUIDE.md)。需要改动 App 本身时，再向本仓库提交 PR。

## 许可

本项目依照 GPL-3.0 发布，提交的代码也以 GPL-3.0 发布。引用他人的代码时，请保留原有的版权和许可声明。
