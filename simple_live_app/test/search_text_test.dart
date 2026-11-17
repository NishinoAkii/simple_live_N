// 搜索用的文字处理：规范化、繁转简、拼音、首字母、模糊打分
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/modules/search/text/search_text.dart';

int score(String query, String name) =>
    searchScore(SearchKey(query), SearchKey(name));

void main() {
  group("规范化", () {
    test("全角转半角、合并空白、转小写", () {
      expect(SearchText.normalize("ＸＱＣ　Ｌｉｖｅ"), "xqc live");
      expect(SearchText.normalize("  a \t b\n c "), "a b c");
      expect(SearchText.normalize("Shroud"), "shroud");
    });

    test("去零宽字符和首尾的括号引号", () {
      expect(SearchText.normalize("【老番茄】"), "老番茄");
      expect(SearchText.normalize("「一条小团团」"), "一条小团团");
      expect(SearchText.normalize("“张大仙”"), "张大仙");
      expect(SearchText.normalize("《（xqc）》"), "xqc");
      expect(SearchText.normalize("老​番﻿茄"), "老番茄");
      // 中间的括号保留
      expect(SearchText.normalize("a(b)c"), "a(b)c");
    });
  });

  group("繁转简", () {
    test("逐字转换，简体和其他字符不变", () {
      expect(SearchText.toSimplified("東雪蓮"), "东雪莲");
      expect(SearchText.toSimplified("張大仙"), "张大仙");
      expect(SearchText.toSimplified("直播間"), "直播间");
      expect(SearchText.toSimplified("老番茄 OvO"), "老番茄 OvO");
    });
  });

  group("拼音", () {
    test("全拼不带声调，字母数字保留", () {
      expect(SearchText.toPinyin("老番茄"), "laofanqie");
      expect(SearchText.toPinyin("张大仙"), "zhangdaxian");
      expect(SearchText.toPinyin("一条小团团OvO"), "yitiaoxiaotuantuanovo");
      expect(SearchText.toPinyin("XTT甜甜"), "xtttiantian");
      // ü 写成 v
      expect(SearchText.toPinyin("绿"), "lv");
      expect(SearchText.toPinyin("〇"), "ling");
      expect(SearchText.toPinyin("！？"), "");
    });

    test("首字母", () {
      expect(SearchText.toInitials("老番茄"), "lfq");
      expect(SearchText.toInitials("张大仙"), "zdx");
      expect(SearchText.toInitials("一条小团团"), "ytxtt");
      expect(SearchText.toInitials("XTT甜甜"), "xtttt");
    });

    test("单字和范围", () {
      expect(SearchText.pinyinOf("中".runes.first), "zhong");
      expect(SearchText.pinyinOf("a".runes.first), isNull);
      expect(SearchText.hasHan("abc"), isFalse);
      expect(SearchText.hasHan("a中"), isTrue);
    });

    test("SearchKey 预先算好各种形式", () {
      var key = SearchKey("  【張大仙】 ");
      expect(key.text, "张大仙");
      expect(key.pinyin, "zhangdaxian");
      expect(key.initials, "zdx");
      expect(key.hasHan, isTrue);
      expect(SearchKey("zdx").isLatin, isTrue);
      expect(SearchKey("").isEmpty, isTrue);
    });
  });

  group("模糊打分", () {
    test("完全相同 > 前缀 > 包含", () {
      expect(score("老番茄", "老番茄"), 100);
      expect(score("Shroud", "shroud"), 100);
      expect(score("東雪蓮", "东雪莲"), 100);
      expect(score("老番", "老番茄"), 80);
      expect(score("番茄", "老番茄"), 60);
    });

    test("全拼能对上同音错字，首字母前缀", () {
      expect(score("老翻茄", "老番茄"), 50);
      expect(score("张大先", "张大仙"), 50);
      expect(score("laofanqie", "老番茄"), 50);
      expect(score("zhangda", "张大仙"), 50);
      expect(score("lfq", "老番茄"), 45);
      expect(score("zdx", "张大仙"), 45);
      expect(score("ytxtt", "一条小团团OvO"), 45);
    });

    test("拉丁字母拼错一两个", () {
      expect(score("shrod", "shroud"), 30);
      expect(score("shrod", "shroudyrowdy"), 30);
      expect(score("pekoraa", "pekora"), 30);
      // 不到 4 个字母不算拼错
      expect(score("sxr", "shroud"), 0);
      expect(score("shr0", "shroud"), 30);
    });

    test("不相关的是 0", () {
      expect(score("老番茄", "张大仙"), 0);
      expect(score("an", "张大仙"), 0);
      expect(score("", "张大仙"), 0);
      expect(score("xqc", "shroud"), 0);
    });

    test("分数顺序", () {
      var names = ["张大仙的徒弟", "张大仙", "大仙", "zhangdaxian_fan"];
      var query = SearchKey("张大仙");
      var sorted = [...names]..sort((a, b) =>
          searchScore(query, SearchKey(b)) - searchScore(query, SearchKey(a)));
      expect(sorted.first, "张大仙");
      expect(sorted[1], "张大仙的徒弟");
      expect(score("张大仙", "大仙"), 0);
    });
  });
}
