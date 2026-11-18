import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:simple_live_app/app/capture/capture_settings.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/i18n/i18n.dart';

/// 截到的图或录好的视频
class CaptureResult {
  /// 截图（PNG，还在内存里）；录屏时为 null
  final Uint8List? png;

  /// 录屏的文件（视频，流录制时还有同名的 .ass 弹幕）
  final List<String> files;

  /// 文件名（不含扩展名）
  final String baseName;

  /// iOS 画面录制：原生端已经存进了“照片”
  final bool savedToAlbum;

  final Duration duration;
  final int bytes;

  /// 画面录制录到了声音没有（原生端没说时为 null）
  final bool? audio;

  const CaptureResult.image(Uint8List this.png, {required this.baseName})
      : files = const [],
        savedToAlbum = false,
        duration = Duration.zero,
        bytes = 0,
        audio = null;

  const CaptureResult.video(
    this.files, {
    required this.baseName,
    this.savedToAlbum = false,
    this.duration = Duration.zero,
    this.bytes = 0,
    this.audio,
  }) : png = null;

  bool get isVideo => png == null;

  /// 视频文件（不含弹幕文件）
  List<String> get videos =>
      files.where((e) => p.extension(e).toLowerCase() != ".ass").toList();

  /// 录成的 GIF；不是 GIF 时为 null
  String? get gif {
    var list = videos;
    return list.length == 1 && p.extension(list.first).toLowerCase() == ".gif"
        ? list.first
        : null;
  }
}

/// 截图、录屏后能做的事
enum CaptureChoice { save, copy, delete }

/// 存、复制、删：按平台各有做法（见 capture_storage.dart），测试里换成假的
abstract class CaptureSink {
  /// 能不能复制这个结果（不能时不显示“复制”）
  Future<bool> canCopy(CaptureResult result);

  /// 存起来，返回存到哪里（给用户看）
  Future<String> save(CaptureResult result);

  Future<bool> copy(CaptureResult result);

  Future<void> delete(CaptureResult result);
}

/// 截图、录屏之后：按设置直接保存、复制，或者问一下
class CaptureFlow {
  final CaptureSink sink;
  final void Function(String text) toast;

  /// 问用户怎么处理；关掉窗口时为 null
  final Future<CaptureChoice?> Function(CaptureResult result, bool canCopy) ask;

  CaptureFlow({required this.sink, required this.toast, required this.ask});

  Future<void> finish(CaptureResult result, CaptureAfterAction action) async {
    if (result.savedToAlbum) {
      toast("录屏已存到相册".t);
      return;
    }
    var canCopy = await sink.canCopy(result);
    CaptureChoice? choice;
    switch (action) {
      case CaptureAfterAction.ask:
        choice = await ask(result, canCopy);
      case CaptureAfterAction.save:
        choice = CaptureChoice.save;
      case CaptureAfterAction.copy:
        choice = canCopy ? CaptureChoice.copy : CaptureChoice.save;
    }
    if (choice == null) {
      // 关掉了窗口：截图不要了；录好的视频留在原处
      if (result.isVideo && result.files.isNotEmpty) {
        toast("录屏在：{path}".tf({"path": result.videos.firstOrNull ?? ""}));
      }
      return;
    }
    await apply(result, choice);
  }

  Future<void> apply(CaptureResult result, CaptureChoice choice) async {
    switch (choice) {
      case CaptureChoice.save:
        await _save(result,
            done: result.isVideo ? "录屏已保存：{where}".t : "截图已保存：{where}".t);
      case CaptureChoice.copy:
        var ok = false;
        try {
          ok = await sink.copy(result);
        } catch (e) {
          Log.logPrint(e);
        }
        if (ok) {
          toast("已复制到剪贴板".t);
        } else {
          await _save(result, done: "复制没成功，已保存：{where}".t);
        }
      case CaptureChoice.delete:
        try {
          await sink.delete(result);
          toast(result.isVideo ? "录屏已删除".t : "截图已丢弃".t);
        } catch (e) {
          Log.logPrint(e);
          toast("删除失败：{e}".tf({"e": e}));
        }
    }
  }

  /// 到了最长录制时间（或关掉页面）时直接保存，不问
  Future<void> autoSave(CaptureResult result, {required String done}) async {
    if (result.savedToAlbum) {
      toast(done.replaceAll("{where}", "相册".t));
      return;
    }
    await _save(result, done: done);
  }

  Future<void> _save(CaptureResult result, {required String done}) async {
    try {
      var where = await sink.save(result);
      toast(done.replaceAll("{where}", where));
    } catch (e) {
      Log.logPrint(e);
      toast("保存失败：{e}".tf({"e": e}));
    }
  }
}
