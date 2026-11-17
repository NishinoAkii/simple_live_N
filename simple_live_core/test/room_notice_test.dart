import 'package:simple_live_core/simple_live_core.dart';
import 'package:test/test.dart';

/// 直播间公告（聊天区顶上的卡片用）。哔哩哔哩的字段照公开文档和别的项目里存下来的
/// getInfoByRoom 响应写（bilibili-API-collect 的 live/info.md：data.news_info 有
/// uid、ctime、content；样例见 AceDroidX/Shark7、dd-center/bilibili-dd-monitor），没有请求过接口
void main() {
  group("哔哩哔哩 news_info", () {
    test("有公告：取 content", () {
      expect(
        parseBiliRoomNews({
          "room_info": {"title": "出差只能用手机播了", "description": ""},
          "news_info": {
            "uid": 434334701,
            "ctime": "2020-10-26 11:47:20",
            "content": " 每天晚上21:00开播 除了周一是24:00开播！ ",
          },
        }),
        "每天晚上21:00开播 除了周一是24:00开播！",
      );
    });

    test("没写公告：content 是空的", () {
      expect(
        parseBiliRoomNews({
          "news_info": {
            "uid": 730732,
            "ctime": "2026-02-23 21:10:52",
            "content": "",
          },
        }),
        "",
      );
    });

    test("字段缺了、类型不对都不报错", () {
      for (var info in [
        null,
        "",
        [],
        <String, dynamic>{},
        {"news_info": null},
        {"news_info": "x"},
        {"news_info": <String, dynamic>{}},
        {
          "news_info": {"content": null, "ctime": null},
        },
      ]) {
        expect(parseBiliRoomNews(info), "");
      }
    });
  });

  group("变成纯文字", () {
    test("纯文字原样，首尾空白和空行去掉", () {
      expect(
        plainRoomText("  每天20点见～粉丝群：673912408 \n"),
        "每天20点见～粉丝群：673912408",
      );
      expect(plainRoomText("第一行\r\n\r\n  \n第二行\n\n"), "第一行\n第二行");
      expect(plainRoomText("a \t  b　　c"), "a b c");
    });

    test("空的、null、\"null\"", () {
      expect(plainRoomText(null), "");
      expect(plainRoomText(""), "");
      expect(plainRoomText("  \n "), "");
      expect(plainRoomText("null"), "");
      expect(plainRoomText("<p> </p><p><br></p>"), "");
    });

    test("HTML：段落和 br 换行，标签去掉，实体还原", () {
      expect(
        plainRoomText(
          "<p>这里是哔哩哔哩官方音乐台喔！</p><p>一起来听音乐吧ε=ε=(ノ≧∇≦)ノ</p>"
          "<p>没想到蒸汽配圣诞下装，意外的很暴露呢=3=</p>\n",
        ),
        "这里是哔哩哔哩官方音乐台喔！\n一起来听音乐吧ε=ε=(ノ≧∇≦)ノ\n没想到蒸汽配圣诞下装，意外的很暴露呢=3=",
      );
      expect(
        plainRoomText("<p>测试公告第一行</p><p>第二行 &amp; 更多<br/>第三行</p>"),
        "测试公告第一行\n第二行 & 更多\n第三行",
      );
      expect(
        plainRoomText(
          '<div style="color:red"><h1>标题</h1><a href="https://example.com" '
          'target="_blank">微博</a>&nbsp;&#124;&#x20;<IMG src="a.png">群</div>',
        ),
        "标题\n微博 | 群",
      );
    });

    test("转义过一遍的 HTML（有的直播间的简介是这样）", () {
      expect(
        plainRoomText(
          "&lt;p&gt;&lt;span style=&quot;color: #993366;&quot;&gt;⭐粉丝群：1132086072⭐ "
          "&lt;/span&gt;&lt;/p&gt;\n&lt;p&gt;&lt;span style=&quot;color: #993366;&quot;&gt;"
          "⭐直播时间：每天15:00-17:30 20:00-随机⭐&lt;/span&gt;&lt;/p&gt;\n"
          "&lt;p&gt; &lt;/p&gt;\n&lt;p&gt; &lt;/p&gt;",
        ),
        "⭐粉丝群：1132086072⭐\n⭐直播时间：每天15:00-17:30 20:00-随机⭐",
      );
    });

    test("style、script、注释连内容一起去掉", () {
      expect(
        plainRoomText(
          "<style>.a{color:red}</style><!-- 隐藏 -->你好<script>alert(1)</script>",
        ),
        "你好",
      );
    });

    test("不是标签的尖括号留着", () {
      expect(plainRoomText("时间 <8点> 开播，1 < 2 > 0"), "时间 <8点> 开播，1 < 2 > 0");
      expect(plainRoomText("爱你 &lt;3"), "爱你 <3");
      expect(
        plainRoomText("A&B &unknown; &#0; &#xD800;"),
        "A&B &unknown; &#0; &#xD800;",
      );
    });

    test("太长的截断，不拆开表情", () {
      expect(plainRoomText("一二三四五六", maxLength: 4), "一二三四…");
      expect(plainRoomText("一二三四", maxLength: 4), "一二三四");
      expect(plainRoomText("😀😀😀", maxLength: 2), "😀😀…");
    });
  });
}
