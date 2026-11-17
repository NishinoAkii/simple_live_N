/// 界面文字的翻译入口。源码里的简体中文就是“键”：
///
///     "复制弹幕".t                        // 当前语言的译文，没有时原样返回
///     "共 {count} 条".tf({"count": n})    // 译文里的 {count} 换成值
///
/// 核心库不管有哪些语言。应用启动时把 [lookup] 接到自己的语言表上；
/// 没接时（测试、命令行工具）所有文字都是简体中文
class CoreText {
  /// 查当前语言里 [key] 的译文，没有时返回 null
  static String? Function(String key)? lookup;

  /// 当前语言的整张表。后台 isolate 有自己的一份静态变量，起它的时候把表带过去，
  /// 在那边用 [use] 接上；没接（简体中文）时为 null
  static Map<String, String> Function()? snapshot;

  /// 在后台 isolate 里用带过来的表（[snapshot] 的结果）
  static void use(Map<String, String>? table) {
    if (table != null && table.isNotEmpty) {
      lookup = (key) => table[key];
    }
  }

  /// 同一段中文在两个地方要译成不同的词时，键后面加“##说明”分开，
  /// 如“关注”（标签页）和“关注##verb”（句子里的动词）。
  /// 译文表里没有带说明的那条时，用不带说明的；都没有就显示“##”前面的原文
  static String text(String key) {
    var found = lookup?.call(key);
    if (found != null) return found;
    var cut = key.indexOf("##");
    if (cut < 0) return key;
    var base = key.substring(0, cut);
    return lookup?.call(base) ?? base;
  }

  static final RegExp _placeholder = RegExp(r"\{(\w+)\}");

  /// 把 [text] 里的 {名字} 换成 [args] 里对应的值；[args] 里没有的原样留着
  static String fill(String text, Map<String, Object?> args) =>
      text.replaceAllMapped(_placeholder, (m) {
        var name = m.group(1)!;
        return args.containsKey(name) ? "${args[name]}" : m.group(0)!;
      });

  static String format(String key, Map<String, Object?> args) =>
      fill(text(key), args);
}

extension I18nText on String {
  /// 这段文字在当前界面语言里的写法
  String get t => CoreText.text(this);

  /// 同 [t]，再把 {名字} 换成 [args] 里的值
  String tf(Map<String, Object?> args) => CoreText.format(this, args);
}
