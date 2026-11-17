"""生成搜索用的拼音表和繁简表（Dart 源文件）。

数据来源（需要先下载到本地，脚本不联网）：
  - 拼音：mozillazg/pinyin-data 的 pinyin.txt（MIT）
    https://raw.githubusercontent.com/mozillazg/pinyin-data/master/pinyin.txt
  - 繁转简：OpenCC 的 data/dictionary/TSCharacters.txt（Apache-2.0）
    https://raw.githubusercontent.com/BYVoid/OpenCC/master/data/dictionary/TSCharacters.txt

用法（在 simple_live_app 目录）：
  python tool/gen_search_text_data.py <pinyin.txt> <TSCharacters.txt>

生成：
  lib/modules/search/text/pinyin_table.g.dart  基本区汉字（U+4E00–U+9FFF）→ 不带声调的拼音
  lib/modules/search/text/ts_table.g.dart      繁体单字 → 简体单字

规则：
  - 拼音取 pinyin.txt 里每个字的第一个读音，去掉声调，ü 写成 v（和拼音输入法一致）；
    [OVERRIDES] 里的几个字改用更常用的读音（第一个读音是少见读音的）。
  - 繁简表只要两边都是 BMP 内单个字符、且简体和繁体不同的项，有多个简体时取第一个。
"""
import os
import sys
import unicodedata

START = 0x4E00
END = 0x9FFF

# 第一个读音不是常用读音、又常出现在名字里的字
OVERRIDES = {
    "茄": "qie",  # pinyin.txt 第一个读音是 jiā（雪茄），常用的是 qié（番茄）
}

# 64 个可以直接写进 Dart 字符串的字符（不含 $、\、引号）
ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"

HERE = os.path.dirname(os.path.abspath(__file__))
OUT_DIR = os.path.join(os.path.dirname(HERE), "lib", "modules", "search", "text")


def toneless(reading):
    """去掉声调：ǖ/ü → v，其余拆成基本字母 + 组合符号后去掉符号"""
    s = reading.strip().lower()
    for ch in "üǖǘǚǜ":
        s = s.replace(ch, "v")
    s = unicodedata.normalize("NFD", s)
    s = "".join(c for c in s if not unicodedata.combining(c))
    return "".join(c for c in s if "a" <= c <= "z")


def read_pinyin(path):
    table = {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.split("#", 1)[0].strip()
            if not line.startswith("U+"):
                continue
            code, readings = line.split(":", 1)
            cp = int(code[2:], 16)
            if not START <= cp <= END:
                continue
            first = readings.split(",")[0]
            py = toneless(first)
            if py:
                table[cp] = py
    for ch, py in OVERRIDES.items():
        table[ord(ch)] = py
    return table


def read_ts(path):
    pairs = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            if line.startswith("#") or not line.strip():
                continue
            parts = line.rstrip("\n").split("\t")
            if len(parts) < 2:
                continue
            trad = parts[0].strip()
            simp = parts[1].split(" ")[0].strip()
            if len(trad) != 1 or len(simp) != 1 or trad == simp:
                continue
            if ord(trad) > 0xFFFF or ord(simp) > 0xFFFF:
                continue
            pairs.append((trad, simp))
    pairs.sort()
    return pairs


def dart_string_lines(text, width):
    return ["  '" + text[i:i + width] + "'" for i in range(0, len(text), width)]


def write_pinyin(table):
    syllables = sorted(set(table.values()))
    if len(syllables) + 1 > len(ALPHABET) ** 2:
        raise SystemExit("拼音太多，两位编码放不下")
    index = {s: i + 1 for i, s in enumerate(syllables)}  # 0 = 没有读音
    codes = []
    for cp in range(START, END + 1):
        i = index.get(table.get(cp, ""), 0)
        codes.append(ALPHABET[i // 64] + ALPHABET[i % 64])
    body = "".join(codes)
    lines = [
        "// 由 tool/gen_search_text_data.py 生成，不要手改。",
        "//",
        "// 数据来源：mozillazg/pinyin-data 的 pinyin.txt（MIT License，Copyright (c) 2016 mozillazg）",
        "// https://github.com/mozillazg/pinyin-data",
        "// 每个字取第一个读音，去掉声调（ü 写成 v）；个别字改用常用读音，见生成脚本。",
        "",
        "/// 拼音表覆盖的范围（CJK 统一汉字基本区）",
        "const int kPinyinStart = 0x%04X;" % START,
        "const int kPinyinEnd = 0x%04X;" % END,
        "",
        "/// 编码用的 64 个字符：每个字两位，值为 [kPinyinSyllables] 的序号（0 为没有读音）",
        "const String kPinyinAlphabet =",
        "    '%s';" % ALPHABET,
        "",
        "/// 全部不带声调的拼音，空格分隔，第 n 个的序号为 n（从 1 开始）",
        "const String kPinyinSyllables =",
    ]
    lines += ["    " + l.strip() for l in dart_string_lines(" ".join(syllables), 96)]
    lines[-1] += ";"
    lines += [
        "",
        "/// 从 [kPinyinStart] 开始每个字两位",
        "const String kPinyinCodes =",
    ]
    lines += ["    " + l.strip() for l in dart_string_lines(body, 96)]
    lines[-1] += ";"
    path = os.path.join(OUT_DIR, "pinyin_table.g.dart")
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines) + "\n")
    print("pinyin:", len(table), "chars,", len(syllables), "syllables ->", path,
          os.path.getsize(path), "bytes")


def write_ts(pairs):
    trad = "".join(p[0] for p in pairs)
    simp = "".join(p[1] for p in pairs)
    lines = [
        "// 由 tool/gen_search_text_data.py 生成，不要手改。",
        "//",
        "// 数据来源：OpenCC 的 data/dictionary/TSCharacters.txt（Apache License 2.0）",
        "// https://github.com/BYVoid/OpenCC",
        "// 只保留两边都是单个字符的项，有多个简体时取第一个。",
        "",
        "/// 繁体字，和 [kSimplifiedChars] 一一对应",
        "const String kTraditionalChars =",
    ]
    lines += ["    " + l.strip() for l in dart_string_lines(trad, 40)]
    lines[-1] += ";"
    lines += [
        "",
        "/// 对应的简体字",
        "const String kSimplifiedChars =",
    ]
    lines += ["    " + l.strip() for l in dart_string_lines(simp, 40)]
    lines[-1] += ";"
    path = os.path.join(OUT_DIR, "ts_table.g.dart")
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines) + "\n")
    print("traditional->simplified:", len(pairs), "pairs ->", path, os.path.getsize(path), "bytes")


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        raise SystemExit(2)
    os.makedirs(OUT_DIR, exist_ok=True)
    write_pinyin(read_pinyin(sys.argv[1]))
    write_ts(read_ts(sys.argv[2]))


if __name__ == "__main__":
    main()
