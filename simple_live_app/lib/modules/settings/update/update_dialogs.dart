import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/i18n/i18n.dart';
import 'package:simple_live_app/services/app_update/release_api.dart';
import 'package:simple_live_app/services/app_update/release_models.dart';
import 'package:simple_live_app/services/app_update/update_downloader.dart';

/// 更新对话框里点了哪个
enum UpdateChoice { update, later, skip }

/// 有新版本时的对话框：版本、日期、“在 GitHub 查看”，当前版本，安装包多大、下载以后会怎样，
/// 更新内容；跳过这个版本 / 稍后 / 立即更新。这台设备没有能在 App 里装的包时，
/// 主按钮是“前往下载”（打开 Release 网页）
class UpdateDialog extends StatelessWidget {
  final AppRelease release;
  final LocalBuild local;

  /// 这台设备要下载的安装包；没有时为 null
  final ReleaseAsset? asset;

  /// 下载以后会怎样（各平台的安装方式给的一句话）
  final String installNote;

  /// 这个版本的网页；空着时不显示“在 GitHub 查看”
  final String pageUrl;

  /// 打开网页
  final Future<void> Function(String url)? openUrl;

  const UpdateDialog({
    required this.release,
    required this.local,
    this.asset,
    this.installNote = "",
    this.pageUrl = "",
    this.openUrl,
    super.key,
  });

  static Future<UpdateChoice?> show(UpdateDialog dialog) =>
      Get.dialog<UpdateChoice>(dialog, barrierDismissible: false);

  /// 安装包大小和下载以后会怎样，如“安装包 38.20 MB · 下载完成后打开系统安装界面”
  String get installLine {
    var asset = this.asset;
    if (asset == null) {
      return "";
    }
    return [
      if (asset.size > 0)
        "安装包 {size}".tf({"size": Utils.parseFileSize(asset.size)}),
      if (installNote.isNotEmpty) installNote,
    ].join(" · ");
  }

  @override
  Widget build(BuildContext context) {
    var date = release.publishedAt;
    var info = [
      ReleaseParser.displayVersion(release),
      if (date != null) DateFormat("yyyy-MM-dd").format(date.toLocal()),
    ].join(" · ");
    var current =
        local.build > 0 ? "${local.version}（${local.build}）" : local.version;
    var grey =
        Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.grey);
    var open = openUrl;
    var line = installLine;
    var height = MediaQuery.of(context).size.height;
    return AlertDialog(
      title: Text("发现新版本".t),
      // 小屏幕上整个内容可以滚，按钮一直在下面
      scrollable: true,
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              children: [
                Text(info, style: Theme.of(context).textTheme.titleMedium),
                if (open != null && pageUrl.isNotEmpty)
                  TextButton.icon(
                    onPressed: () => open(pageUrl),
                    icon: const Icon(Icons.open_in_new, size: 16),
                    label: Text("在 GitHub 查看".t),
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
              ],
            ),
            AppStyle.vGap4,
            Text("当前版本 {version}".tf({"version": current}), style: grey),
            if (line.isNotEmpty) ...[
              AppStyle.vGap4,
              Text(line, style: grey),
            ],
            AppStyle.vGap12,
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: (height * 0.35).clamp(120.0, 480.0),
              ),
              child: SingleChildScrollView(
                child: ReleaseNotesView(body: release.body),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(UpdateChoice.skip),
          child: Text("跳过这个版本".t),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(UpdateChoice.later),
          child: Text("稍后".t),
        ),
        if (asset != null)
          FilledButton(
            onPressed: () => Navigator.of(context).pop(UpdateChoice.update),
            child: Text("立即更新".t),
          )
        else
          FilledButton.icon(
            onPressed: () => Navigator.of(context).pop(UpdateChoice.update),
            icon: const Icon(Icons.open_in_new, size: 18),
            label: Text("前往下载".t),
          ),
      ],
    );
  }
}

/// 更新内容的一行
class NoteLine {
  /// 0 正文，1 标题，2 列表项
  final int kind;

  /// 列表的缩进层级
  final int level;
  final String text;

  const NoteLine(this.kind, this.text, {this.level = 0});
}

/// Release 正文（CHANGELOG 的一节）：认标题、列表，链接和加粗只留文字
class ReleaseNotesView extends StatelessWidget {
  final String body;

  const ReleaseNotesView({required this.body, super.key});

  static final RegExp _link = RegExp(r"\[([^\]]*)\]\([^)]*\)");
  static final RegExp _emphasis = RegExp(r"\*\*|__|`");
  static final RegExp _bullet = RegExp(r"^(\s*)[-*+]\s+(.*)$");
  static final RegExp _heading = RegExp(r"^#{1,6}\s+(.*)$");

  static String _inline(String text) =>
      text.replaceAllMapped(_link, (m) => m[1]!).replaceAll(_emphasis, "");

  static List<NoteLine> parse(String body) {
    var lines = <NoteLine>[];
    for (var raw in body.replaceAll("\r\n", "\n").split("\n")) {
      if (raw.trim().isEmpty) {
        continue;
      }
      var heading = _heading.firstMatch(raw.trim());
      if (heading != null) {
        lines.add(NoteLine(1, _inline(heading[1]!)));
        continue;
      }
      var bullet = _bullet.firstMatch(raw);
      if (bullet != null) {
        lines.add(NoteLine(
          2,
          _inline(bullet[2]!),
          level: bullet[1]!.replaceAll("\t", "  ").length ~/ 2,
        ));
        continue;
      }
      lines.add(NoteLine(0, _inline(raw.trim())));
    }
    return lines;
  }

  @override
  Widget build(BuildContext context) {
    var lines = parse(body);
    if (lines.isEmpty) {
      return Text("这个版本没有写更新内容".t);
    }
    var theme = Theme.of(context).textTheme;
    return SelectionArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var line in lines)
            switch (line.kind) {
              1 => Padding(
                  padding: const EdgeInsets.only(top: 8, bottom: 4),
                  child: Text(line.text, style: theme.titleSmall),
                ),
              2 => Padding(
                  padding: EdgeInsets.only(left: 12.0 * line.level, bottom: 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text("• "),
                      Expanded(child: Text(line.text)),
                    ],
                  ),
                ),
              _ => Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(line.text),
                ),
            },
        ],
      ),
    );
  }
}

/// 下载的过程：交给对话框一个下载函数，它带着进度回调和取消用的 token
typedef UpdateDownloadRun = Future<UpdateDownloadResult> Function(
  void Function(DownloadProgress progress) onProgress,
  CancelToken cancelToken,
);

/// 下载进度对话框：百分比、速度、取消。下完（或出错、取消）自己关掉，
/// 返回 [UpdateDownloadResult]，或者出错时的异常（取消是 [DownloadCancelled]）
class UpdateDownloadDialog extends StatefulWidget {
  final UpdateDownloadRun run;

  const UpdateDownloadDialog({required this.run, super.key});

  static Future<Object?> show(UpdateDownloadRun run) => Get.dialog<Object?>(
        UpdateDownloadDialog(run: run),
        barrierDismissible: false,
      );

  @override
  State<UpdateDownloadDialog> createState() => _UpdateDownloadDialogState();
}

class _UpdateDownloadDialogState extends State<UpdateDownloadDialog> {
  final CancelToken _cancel = CancelToken();
  DownloadProgress _progress = const DownloadProgress(DownloadStage.preparing);
  bool _cancelling = false;

  @override
  void initState() {
    super.initState();
    widget.run(_onProgress, _cancel).then(_finish, onError: _finish);
  }

  void _onProgress(DownloadProgress progress) {
    if (mounted) {
      setState(() => _progress = progress);
    }
  }

  void _finish(Object? result) {
    if (mounted) {
      Navigator.of(context).pop(result);
    }
  }

  String get _stageText {
    switch (_progress.stage) {
      case DownloadStage.preparing:
        return "正在准备…".t;
      case DownloadStage.probing:
        return "正在测试下载源的速度…".t;
      case DownloadStage.downloading:
        return "正在从 {source} 下载".tf({"source": _progress.source});
      case DownloadStage.verifying:
        return "正在校验文件…".t;
    }
  }

  @override
  Widget build(BuildContext context) {
    var fraction = _progress.fraction;
    var downloading = _progress.stage == DownloadStage.downloading;
    return PopScope(
      canPop: false,
      child: AlertDialog(
        title: Text("下载更新".t),
        content: SizedBox(
          width: 360,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_stageText),
              AppStyle.vGap12,
              LinearProgressIndicator(value: downloading ? fraction : null),
              AppStyle.vGap8,
              if (downloading)
                Row(
                  children: [
                    Text(
                      fraction == null
                          ? Utils.parseFileSize(_progress.received)
                          : "${(fraction * 100).toStringAsFixed(0)}%",
                    ),
                    const Spacer(),
                    Text("${Utils.parseFileSize(_progress.speed.round())}/s"),
                  ],
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: _cancelling
                ? null
                : () {
                    setState(() => _cancelling = true);
                    _cancel.cancel();
                  },
            child: Text("取消".t),
          ),
        ],
      ),
    );
  }
}
