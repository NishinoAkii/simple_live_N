import 'dart:io';

import 'package:image_gallery_saver_plus/image_gallery_saver_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:simple_live_app/app/capture/capture_flow.dart';
import 'package:simple_live_app/app/capture/capture_meta.dart';
import 'package:simple_live_app/app/capture/capture_settings.dart';
import 'package:simple_live_app/app/capture/native_capture.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/i18n/i18n.dart';

/// 截图、录屏放在哪
class CaptureFolders {
  CaptureFolders._();

  static bool get desktop =>
      Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  static Directory? _defaultDesktop;

  /// 电脑上默认的保存位置：“图片”文件夹里的 SimpleLive
  static Future<Directory> defaultDesktopDir() async {
    if (_defaultDesktop != null) {
      return _defaultDesktop!;
    }
    var pictures = await _picturesDir();
    return _defaultDesktop = Directory(p.join(pictures, "Simple Live N"));
  }

  static Future<String> _picturesDir() async {
    var env = Platform.environment;
    var home = env["HOME"] ?? env["USERPROFILE"] ?? "";
    if (Platform.isWindows) {
      // “图片”可能被挪到了别处（如 OneDrive），按注册表里的位置
      try {
        var r = await Process.run("reg", [
          "query",
          r"HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders",
          "/v",
          "My Pictures",
        ]);
        var match = RegExp(r"My Pictures\s+REG_\w+\s+(.+)")
            .firstMatch(r.stdout.toString());
        var raw = match?.group(1)?.trim() ?? "";
        if (raw.isNotEmpty) {
          return raw.replaceAllMapped(
            RegExp(r"%([^%]+)%"),
            (m) => env[m[1]!] ?? env[m[1]!.toUpperCase()] ?? m[0]!,
          );
        }
      } catch (e) {
        Log.logPrint(e);
      }
      return p.join(env["USERPROFILE"] ?? home, "Pictures");
    }
    if (Platform.isLinux) {
      try {
        var r = await Process.run("xdg-user-dir", ["PICTURES"]);
        var dir = r.stdout.toString().trim();
        if (r.exitCode == 0 && dir.isNotEmpty && dir != home) {
          return dir;
        }
      } catch (_) {}
    }
    return p.join(home, "Pictures");
  }

  /// 电脑上实际用的保存位置：设置里选的，或者默认的；建不了时换到“下载”里的 SimpleLive
  static Future<Directory> desktopDir() async {
    var custom = CaptureSettings.instance.saveDir.value;
    var candidates = <Future<Directory?> Function()>[
      if (custom.isNotEmpty) () async => Directory(custom),
      defaultDesktopDir,
      () async {
        var downloads = await getDownloadsDirectory();
        return downloads == null
            ? null
            : Directory(p.join(downloads.path, "Simple Live N"));
      },
      () async => Directory(p.join(
          (await getApplicationDocumentsDirectory()).path, "Simple Live N")),
    ];
    Object? lastError;
    for (var candidate in candidates) {
      try {
        var dir = await candidate();
        if (dir == null) {
          continue;
        }
        await dir.create(recursive: true);
        // 能不能写（macOS 没有“图片”权限时建得了、写不进）
        var probe = File(p.join(dir.path, ".simplelive_write_test"));
        await probe.writeAsString("");
        await probe.delete();
        return dir;
      } catch (e) {
        lastError = e;
      }
    }
    throw lastError ?? const FileSystemException("no folder for captures");
  }

  /// 手机上录屏先放在应用自己的文件夹里，保存时再放进相册
  static Future<Directory> mobileWorkDir() async {
    Directory? base;
    if (Platform.isAndroid) {
      try {
        base = await getExternalStorageDirectory();
      } catch (_) {}
    }
    base ??= await getApplicationDocumentsDirectory();
    var dir = Directory(p.join(base.path, "capture"));
    await dir.create(recursive: true);
    return dir;
  }

  /// 录屏写到哪个文件夹
  static Future<Directory> recordDir() =>
      desktop ? desktopDir() : mobileWorkDir();
}

/// 按平台存、复制、删：电脑存进保存位置；手机存进系统相册
/// （安卓是“图片”“影片”，现在用的保存插件不能指定 SimpleLive 相册）
class DefaultCaptureSink implements CaptureSink {
  @override
  Future<bool> canCopy(CaptureResult result) async {
    // GIF 当图片复制，手机上也行；原生端没有 copyGif 时和视频一样
    if (result.gif != null && await CaptureClipboard.supportsGif()) {
      return true;
    }
    return result.isVideo
        ? CaptureClipboard.supportsFiles()
        : CaptureClipboard.supported();
  }

  @override
  Future<bool> copy(CaptureResult result) async {
    var gif = result.gif;
    if (gif != null && await CaptureClipboard.supportsGif()) {
      return CaptureClipboard.copyGif(gif);
    }
    if (result.isVideo) {
      return CaptureClipboard.copyFiles(result.files);
    }
    return CaptureClipboard.copyImage(result.png!);
  }

  @override
  Future<void> delete(CaptureResult result) async {
    for (var path in result.files) {
      var file = File(path);
      if (await file.exists()) {
        await file.delete();
      }
    }
  }

  @override
  Future<String> save(CaptureResult result) async {
    if (CaptureFolders.desktop) {
      if (!result.isVideo) {
        var dir = await CaptureFolders.desktopDir();
        var file = uniqueCaptureFile(dir, result.baseName, "png");
        await file.writeAsBytes(result.png!, flush: true);
        return file.path;
      }
      // 录屏一开始就写在保存位置里
      return result.videos.firstOrNull ?? result.files.firstOrNull ?? "";
    }
    return _saveMobile(result);
  }

  Future<String> _saveMobile(CaptureResult result) async {
    if (!await Utils.checkPhotoPermission()) {
      throw Exception("没有相册权限".t);
    }
    if (!result.isVideo) {
      var temp = await getTemporaryDirectory();
      // 临时文件用英文名；相册里的名字安卓按 name 起
      var file = File(p.join(
          temp.path, "capture_${DateTime.now().millisecondsSinceEpoch}.png"));
      await file.writeAsBytes(result.png!, flush: true);
      try {
        await _toGallery(file.path, result.baseName);
      } finally {
        await file.delete().catchError((_) => file);
      }
      return "相册".t;
    }
    var videos = result.videos;
    // iOS 的“照片”收不了 MKV（流录制）：交给系统的分享，可以存到“文件”；GIF 能进相册
    if (Platform.isIOS &&
        videos.any((e) =>
            !const {".mp4", ".gif"}.contains(p.extension(e).toLowerCase()))) {
      await SharePlus.instance.share(
        ShareParams(files: [for (var e in result.files) XFile(e)]),
      );
      return p.dirname(videos.firstOrNull ?? "");
    }
    for (var path in videos) {
      await _toGallery(path, p.basenameWithoutExtension(path));
      await File(path).delete().catchError((_) => File(path));
    }
    var sidecars = result.files.where((e) => !videos.contains(e)).toList();
    if (sidecars.isNotEmpty) {
      return "{where}（弹幕文件在 {dir}）".tf({
        "where": "相册".t,
        "dir": p.dirname(sidecars.first),
      });
    }
    return "相册".t;
  }

  static Future<void> _toGallery(String path, String name) async {
    Object? raw;
    if (Platform.isIOS) {
      var image =
          const {".png", ".gif"}.contains(p.extension(path).toLowerCase());
      // 图片用文件地址存，保留 PNG 里的信息、GIF 的动画（直接给数据会被重新压成 JPEG）
      raw = await ImageGallerySaverPlus.saveFile(
        image ? Uri.file(path).toString() : path,
        name: name,
        isReturnPathOfIOS: image,
      );
    } else {
      raw = await ImageGallerySaverPlus.saveFile(path, name: name);
    }
    if (raw is Map && raw["isSuccess"] != true) {
      throw Exception(raw["errorMessage"] ?? "存到相册失败".t);
    }
  }
}
