import 'dart:convert';

import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/modules/search/text/search_text.dart';
import 'package:simple_live_app/services/local_storage_service.dart';

/// 搜索历史（最近搜过的关键词），存在 LocalStorage 里，最多 [kMax] 条，新的在前
class SearchHistoryStore {
  static const int kMax = 30;

  /// 读写存储的函数，测试时可以替换
  final String Function() _read;
  final void Function(String value) _write;

  SearchHistoryStore({
    String Function()? read,
    void Function(String value)? write,
  })  : _read = read ??
            (() => LocalStorageService.instance
                .getValue(LocalStorageService.kSearchHistory, "[]")),
        _write = write ??
            ((value) => LocalStorageService.instance
                .setValue(LocalStorageService.kSearchHistory, value));

  List<String> load() {
    try {
      var list = json.decode(_read());
      if (list is List) {
        return list
            .map((e) => e.toString())
            .where((e) => e.trim().isNotEmpty)
            .take(kMax)
            .toList();
      }
    } catch (e) {
      Log.logPrint(e);
    }
    return [];
  }

  void _save(List<String> list) {
    _write(json.encode(list));
  }

  /// 记下一次搜索，返回新的列表
  List<String> add(String keyword) {
    var list = addSearchHistory(load(), keyword, max: kMax);
    _save(list);
    return list;
  }

  List<String> remove(String keyword) {
    var list = load()..remove(keyword);
    _save(list);
    return list;
  }

  void clear() {
    _save([]);
  }
}

/// 把 [keyword] 放到最前面：去掉首尾空白，和已有的（规范化后相同的）合并，最多 [max] 条
List<String> addSearchHistory(List<String> list, String keyword,
    {int max = SearchHistoryStore.kMax}) {
  var text = keyword.trim();
  if (text.isEmpty) return List.of(list);
  var key = SearchText.normalize(text);
  var result = <String>[
    text,
    ...list.where((e) => SearchText.normalize(e) != key),
  ];
  return result.length > max ? result.sublist(0, max) : result;
}
